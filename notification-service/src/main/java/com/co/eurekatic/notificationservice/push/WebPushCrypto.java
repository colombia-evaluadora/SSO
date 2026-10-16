package com.co.eurekatic.notificationservice.push;

import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.interfaces.ECPrivateKey;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPrivateKeySpec;
import java.security.spec.ECPublicKeySpec;
import java.util.Arrays;
import java.util.Base64;

/**
 * Web Push sin dependencias externas, solo con la JCA del JDK:
 * <ul>
 *   <li>RFC 8291 (cifrado del mensaje, content-coding {@code aes128gcm} de RFC 8188);</li>
 *   <li>RFC 8292 (VAPID: JWT ES256 firmado con la clave privada propia).</li>
 * </ul>
 * Se evita {@code nl.martijndwars:web-push}: sin releases desde 2021 y arrastra
 * {@code bcprov-jdk15on}, que choca con el {@code bcprov-jdk18on} de common.
 *
 * <p>Formato de claves: el de {@code web-push generate-vapid-keys} y del navegador
 * (base64url sin relleno). Publica = punto P-256 sin comprimir (65 bytes),
 * privada = escalar de 32 bytes.
 */
public final class WebPushCrypto {

    private static final Base64.Encoder B64 = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder B64D = Base64.getUrlDecoder();
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final int RECORD_SIZE = 4096;
    private static final ECParameterSpec P256 = p256();

    private WebPushCrypto() { }

    public static byte[] b64(String s) {
        return B64D.decode(s.trim().replace('+', '-').replace('/', '_').replace("=", ""));
    }

    public static String b64(byte[] b) {
        return B64.encodeToString(b);
    }

    public static ECPublicKey publicKey(byte[] uncompressed) throws GeneralSecurityException {
        if (uncompressed.length != 65 || uncompressed[0] != 0x04) {
            throw new GeneralSecurityException("Clave publica P-256 invalida");
        }
        BigInteger x = new BigInteger(1, Arrays.copyOfRange(uncompressed, 1, 33));
        BigInteger y = new BigInteger(1, Arrays.copyOfRange(uncompressed, 33, 65));
        return (ECPublicKey) KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(new ECPoint(x, y), P256));
    }

    public static ECPrivateKey privateKey(byte[] scalar) throws GeneralSecurityException {
        return (ECPrivateKey) KeyFactory.getInstance("EC")
                .generatePrivate(new ECPrivateKeySpec(new BigInteger(1, scalar), P256));
    }

    public static byte[] uncompressed(ECPublicKey key) {
        byte[] out = new byte[65];
        out[0] = 0x04;
        copiar(key.getW().getAffineX(), out, 1);
        copiar(key.getW().getAffineY(), out, 33);
        return out;
    }

    public static KeyPair generarPar() throws GeneralSecurityException {
        KeyPairGenerator gen = KeyPairGenerator.getInstance("EC");
        gen.initialize(new ECGenParameterSpec("secp256r1"), RANDOM);
        return gen.generateKeyPair();
    }

    /**
     * Cifra {@code payload} para la suscripcion ({@code p256dh}, {@code auth}).
     * Devuelve el cuerpo completo: cabecera (salt, rs, keyid) + registro cifrado.
     */
    public static byte[] cifrar(byte[] payload, byte[] uaPublic, byte[] authSecret) throws GeneralSecurityException {
        return cifrar(payload, uaPublic, authSecret, generarPar(), aleatorio(16));
    }

    static byte[] cifrar(byte[] payload, byte[] uaPublic, byte[] authSecret, KeyPair efimero, byte[] salt)
            throws GeneralSecurityException {
        if (payload.length > RECORD_SIZE - 17 - 86) {
            throw new GeneralSecurityException("Payload demasiado grande para un registro");
        }
        byte[] asPublic = uncompressed((ECPublicKey) efimero.getPublic());
        byte[] ecdh = ecdh((ECPrivateKey) efimero.getPrivate(), publicKey(uaPublic));
        byte[] cek = new byte[16];
        byte[] nonce = new byte[12];
        derivar(ecdh, authSecret, uaPublic, asPublic, salt, cek, nonce);

        byte[] plano = Arrays.copyOf(payload, payload.length + 1);
        plano[payload.length] = 0x02; // delimitador del ultimo registro, sin relleno
        Cipher aes = Cipher.getInstance("AES/GCM/NoPadding");
        aes.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(cek, "AES"), new GCMParameterSpec(128, nonce));
        byte[] cifrado = aes.doFinal(plano);

        return ByteBuffer.allocate(16 + 4 + 1 + asPublic.length + cifrado.length)
                .put(salt).putInt(RECORD_SIZE).put((byte) asPublic.length).put(asPublic).put(cifrado)
                .array();
    }

    /** Lado del navegador; solo para pruebas de ida y vuelta. */
    static byte[] descifrar(byte[] cuerpo, ECPrivateKey uaPrivate, byte[] uaPublic, byte[] authSecret)
            throws GeneralSecurityException {
        ByteBuffer buf = ByteBuffer.wrap(cuerpo);
        byte[] salt = new byte[16];
        buf.get(salt);
        buf.getInt();
        byte[] asPublic = new byte[buf.get() & 0xff];
        buf.get(asPublic);
        byte[] cifrado = new byte[buf.remaining()];
        buf.get(cifrado);
        byte[] ecdh = ecdh(uaPrivate, publicKey(asPublic));
        byte[] cek = new byte[16];
        byte[] nonce = new byte[12];
        derivar(ecdh, authSecret, uaPublic, asPublic, salt, cek, nonce);
        Cipher aes = Cipher.getInstance("AES/GCM/NoPadding");
        aes.init(Cipher.DECRYPT_MODE, new SecretKeySpec(cek, "AES"), new GCMParameterSpec(128, nonce));
        byte[] plano = aes.doFinal(cifrado);
        int fin = plano.length - 1;
        while (fin >= 0 && plano[fin] == 0) fin--;
        return Arrays.copyOf(plano, fin);
    }

    /** JWT VAPID (RFC 8292) para el origen del push service. */
    public static String vapidJwt(String audiencia, String subject, long expiraEpochSeg, ECPrivateKey clave)
            throws GeneralSecurityException {
        String header = b64("{\"typ\":\"JWT\",\"alg\":\"ES256\"}".getBytes(StandardCharsets.UTF_8));
        String claims = b64(("{\"aud\":\"" + json(audiencia) + "\",\"exp\":" + expiraEpochSeg
                + ",\"sub\":\"" + json(subject) + "\"}").getBytes(StandardCharsets.UTF_8));
        String firmado = header + "." + claims;
        Signature es256 = Signature.getInstance("SHA256withECDSAinP1363Format");
        es256.initSign(clave);
        es256.update(firmado.getBytes(StandardCharsets.US_ASCII));
        return firmado + "." + b64(es256.sign());
    }

    private static void derivar(byte[] ecdh, byte[] authSecret, byte[] uaPublic, byte[] asPublic, byte[] salt,
                                byte[] cek, byte[] nonce) throws GeneralSecurityException {
        byte[] prkKey = hmac(authSecret, ecdh);
        byte[] keyInfo = concat("WebPush: info\0".getBytes(StandardCharsets.US_ASCII), uaPublic, asPublic, new byte[] {1});
        byte[] ikm = hmac(prkKey, keyInfo);
        byte[] prk = hmac(salt, ikm);
        System.arraycopy(hmac(prk, concat("Content-Encoding: aes128gcm\0".getBytes(StandardCharsets.US_ASCII),
                new byte[] {1})), 0, cek, 0, 16);
        System.arraycopy(hmac(prk, concat("Content-Encoding: nonce\0".getBytes(StandardCharsets.US_ASCII),
                new byte[] {1})), 0, nonce, 0, 12);
    }

    private static byte[] ecdh(ECPrivateKey priv, ECPublicKey pub) throws GeneralSecurityException {
        KeyAgreement ka = KeyAgreement.getInstance("ECDH");
        ka.init(priv);
        ka.doPhase(pub, true);
        return ka.generateSecret();
    }

    private static byte[] hmac(byte[] key, byte[] data) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(data);
    }

    private static byte[] concat(byte[]... partes) {
        int n = 0;
        for (byte[] p : partes) n += p.length;
        ByteBuffer b = ByteBuffer.allocate(n);
        for (byte[] p : partes) b.put(p);
        return b.array();
    }

    private static byte[] aleatorio(int n) {
        byte[] b = new byte[n];
        RANDOM.nextBytes(b);
        return b;
    }

    private static void copiar(BigInteger v, byte[] out, int offset) {
        byte[] raw = v.toByteArray();
        int len = Math.min(raw.length, 32);
        System.arraycopy(raw, raw.length - len, out, offset + 32 - len, len);
    }

    private static String json(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static ECParameterSpec p256() {
        try {
            AlgorithmParameters params = AlgorithmParameters.getInstance("EC");
            params.init(new ECGenParameterSpec("secp256r1"));
            return params.getParameterSpec(ECParameterSpec.class);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("La JVM no soporta P-256", e);
        }
    }
}
