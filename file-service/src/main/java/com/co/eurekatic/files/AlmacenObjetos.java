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
import software.amazon.awssdk.services.s3.model.PutObjectRequest;

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
}
