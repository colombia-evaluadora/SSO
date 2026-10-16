package com.co.eurekatic.notificationservice.push;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.Signature;
import java.security.interfaces.ECPrivateKey;
import java.security.interfaces.ECPublicKey;
import java.util.Base64;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WebPushCryptoTest {

    @Test
    void cifradoAes128gcmIdaYVuelta() throws Exception {
        KeyPair navegador = WebPushCrypto.generarPar();
        byte[] uaPublic = WebPushCrypto.uncompressed((ECPublicKey) navegador.getPublic());
        byte[] auth = new byte[16];
        new java.security.SecureRandom().nextBytes(auth);
        byte[] payload = "{\"id\":\"x\",\"tipo\":\"CHAT_MENCION\"}".getBytes(StandardCharsets.UTF_8);

        byte[] cuerpo = WebPushCrypto.cifrar(payload, uaPublic, auth);

        // Cabecera RFC 8188: salt(16) + rs(4) + idlen(1) + keyid(65).
        assertThat(cuerpo[20] & 0xff).isEqualTo(65);
        assertThat(cuerpo.length).isEqualTo(16 + 4 + 1 + 65 + payload.length + 1 + 16);
        byte[] plano = WebPushCrypto.descifrar(cuerpo, (ECPrivateKey) navegador.getPrivate(), uaPublic, auth);
        assertThat(new String(plano, StandardCharsets.UTF_8)).isEqualTo(new String(payload, StandardCharsets.UTF_8));
    }

    @Test
    void clavesEnFormatoBase64UrlRoundTrip() throws Exception {
        KeyPair par = WebPushCrypto.generarPar();
        byte[] pub = WebPushCrypto.uncompressed((ECPublicKey) par.getPublic());
        ECPublicKey reconstruida = WebPushCrypto.publicKey(WebPushCrypto.b64(WebPushCrypto.b64(pub)));
        assertThat(reconstruida.getW()).isEqualTo(((ECPublicKey) par.getPublic()).getW());
        assertThatThrownBy(() -> WebPushCrypto.publicKey(new byte[10]))
                .isInstanceOf(java.security.GeneralSecurityException.class);
    }

    @Test
    void jwtVapidFirmadoEs256YVerificable() throws Exception {
        KeyPair par = WebPushCrypto.generarPar();
        byte[] escalar = ((ECPrivateKey) par.getPrivate()).getS().toByteArray();
        ECPrivateKey privada = WebPushCrypto.privateKey(escalar);

        String jwt = WebPushCrypto.vapidJwt("https://fcm.googleapis.com", "mailto:soporte@example.com", 2_000_000_000L, privada);

        String[] partes = jwt.split("\\.");
        assertThat(partes).hasSize(3);
        String claims = new String(Base64.getUrlDecoder().decode(partes[1]), StandardCharsets.UTF_8);
        assertThat(claims).contains("\"aud\":\"https://fcm.googleapis.com\"").contains("\"exp\":2000000000");
        Signature v = Signature.getInstance("SHA256withECDSAinP1363Format");
        v.initVerify(par.getPublic());
        v.update((partes[0] + "." + partes[1]).getBytes(StandardCharsets.US_ASCII));
        assertThat(v.verify(Base64.getUrlDecoder().decode(partes[2]))).isTrue();
    }
}
