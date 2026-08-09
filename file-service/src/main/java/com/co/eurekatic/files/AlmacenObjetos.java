package com.co.eurekatic.files;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.GetObjectPresignRequest;

import java.time.Duration;

import java.io.IOException;
import java.io.InputStream;
import java.net.URI;

/**
 * Subida de objetos a un almacén compatible con S3.
 *
 * <p>El mismo código sirve para Garage en desarrollo y para S3 de AWS
 * en producción: lo único que cambia son endpoint, credenciales y el
 * {@code path-style}.
 *
 * <p>Ese último es la diferencia de configuración que más veces rompe
 * un S3 local. AWS resuelve {@code bucket.s3.amazonaws.com} por DNS;
 * un endpoint local no tiene DNS por bucket, así que el SDK debe pedir
 * {@code /bucket/objeto}. Con {@code path-style} desactivado contra
 * Garage, el cliente intenta resolver un host que no existe y falla con
 * un error de red que no menciona ni buckets ni configuración.
 */
@Component
public class AlmacenObjetos {

    private static final Logger log = LoggerFactory.getLogger(AlmacenObjetos.class);

    private final S3Client s3;
    private final S3Presigner presigner;
    private final String bucket;
    private final String urlPublicaBase;

    public AlmacenObjetos(
            @Value("${files.s3.endpoint:}") String endpoint,
            @Value("${files.s3.region:us-east-1}") String region,
            @Value("${files.s3.bucket}") String bucket,
            @Value("${files.s3.access-key}") String accessKey,
            @Value("${files.s3.secret-key}") String secretKey,
            @Value("${files.s3.path-style:true}") boolean pathStyle,
            @Value("${files.s3.public-base-url:}") String urlPublicaBase) {

        this.bucket = bucket;
        this.urlPublicaBase = urlPublicaBase;

        // Para SUBIR, el cliente habla contra el endpoint interno de
        // Docker (rapido, sin proxy). Para FIRMAR, en cambio, el
        // navegador va a hacer el GET directo al bucket: si firmamos
        // contra el endpoint interno, la URL queda con host=garage y
        // el browser no puede resolverla. Por eso el presigner usa
        // la URL pública (la misma que el front va a llamar).
        //
        // Si `urlPublicaBase` no está seteada, caemos al endpoint
        // interno o a AWS según `endpoint`.
        var builder = S3Client.builder()
                .region(Region.of(region))
                .credentialsProvider(StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(accessKey, secretKey)))
                .serviceConfiguration(S3Configuration.builder()
                        .pathStyleAccessEnabled(pathStyle)
                        .build());

        // Endpoint vacío = AWS real. Cualquier otro valor = almacén
        // local (Garage) o compatible.
        if (endpoint != null && !endpoint.isBlank()) {
            builder = builder.endpointOverride(URI.create(endpoint));
            log.info("AlmacenObjetos: endpoint={} bucket={} pathStyle={}",
                    endpoint, bucket, pathStyle);
        } else {
            log.info("AlmacenObjetos: AWS S3 bucket={} region={}", bucket, region);
        }
        this.s3 = builder.build();

        // Mismas credenciales que el cliente principal; el presigner
        // NO hace la llamada HTTP — sólo arma la URL firmada con
        // SigV4 y los headers correctos para que el navegador haga
        // el GET directo al bucket. El host de la firma tiene que
        // coincidir con el host desde el que el browser descarga,
        // si no Garage responde 400 AuthorizationHeaderMalformed
        // ("the V4 signature does not match the region of the bucket").
        var presignerBuilder = S3Presigner.builder()
                .region(Region.of(region))
                .credentialsProvider(StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(accessKey, secretKey)))
                .serviceConfiguration(S3Configuration.builder()
                        .pathStyleAccessEnabled(pathStyle)
                        .build());
        String hostParaFirma = (urlPublicaBase != null && !urlPublicaBase.isBlank())
                ? urlPublicaBase.replaceAll("/+$", "")
                : endpoint;
        if (hostParaFirma != null && !hostParaFirma.isBlank()) {
            // Si el publicBase trae /<bucket> al final (caso Garage:
            // http://host:3900/eval-col), hay que quitárselo porque
            // el presigner ya prepende /<bucket>/<key>. Sin esto, la
            // URL queda /eval-col/eval-col/<key> y Garage responde 404.
            URI pub = URI.create(hostParaFirma);
            String path = pub.getPath();
            if (path != null && !path.isBlank() && path.equals("/" + bucket)) {
                hostParaFirma = new URI(pub.getScheme(), null, pub.getHost(),
                        pub.getPort(), null, null, null).toString();
            }
            presignerBuilder = presignerBuilder.endpointOverride(URI.create(hostParaFirma));
        }
        this.presigner = presignerBuilder.build();
    }

    /**
     * Sube el contenido y devuelve la URL con la que se registrará en
     * {@code TARCHIVO}.
     *
     * <p>Recibe un {@link InputStream} y el tamaño ya conocido en vez
     * de un array de bytes: cargar el fichero entero en memoria
     * significa que tres subidas simultáneas de 50 MB se comen 150 MB
     * de heap. En una caja con menos de 1 GB disponible eso es la
     * diferencia entre funcionar y volver a swap.
     */
    public String subir(String clave, InputStream contenido, long tamano,
                        String contentType) throws IOException {
        PutObjectRequest req = PutObjectRequest.builder()
                .bucket(bucket)
                .key(clave)
                .contentType(contentType == null ? "application/octet-stream" : contentType)
                .contentLength(tamano)
                .build();

        s3.putObject(req, RequestBody.fromInputStream(contenido, tamano));

        String url = urlPublicaBase == null || urlPublicaBase.isBlank()
                ? "s3://" + bucket + "/" + clave
                : urlPublicaBase.replaceAll("/+$", "") + "/" + clave;
        log.debug("subido {} ({} bytes) -> {}", clave, tamano, url);
        return url;
    }

    /**
     * Genera una URL prefirmada (GET con expiración) para que un
     * navegador descargue el objeto sin pasar por este servicio.
     *
     * <p>La expiración es {@code expiracion} y se aplica aunque el
     * llamante pase null (default 15 min). Pasamos
     * {@code responseContentDisposition} opcional para sugerir nombre
     * de descarga en el cliente sin tener que cambiar la fila en
     * TARCHIVO.
     */
    public java.net.URL firmar(String clave, Duration expiracion,
                               String responseContentDisposition) {
        Duration exp = expiracion == null ? Duration.ofMinutes(15) : expiracion;
        var getObject = GetObjectRequest.builder()
                .bucket(bucket)
                .key(clave)
                .applyMutation(b -> {
                    if (responseContentDisposition != null
                            && !responseContentDisposition.isBlank()) {
                        b.responseContentDisposition(responseContentDisposition);
                    }
                })
                .build();
        GetObjectPresignRequest req = GetObjectPresignRequest.builder()
                .signatureDuration(exp)
                .getObjectRequest(getObject)
                .build();
        java.net.URL url = presigner.presignGetObject(req).url();
        log.debug("firmada {} ({} seg) -> {}", clave, exp.toSeconds(), url);
        return url;
    }
}
