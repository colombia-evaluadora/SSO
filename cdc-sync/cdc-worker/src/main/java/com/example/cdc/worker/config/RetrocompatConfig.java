package com.example.cdc.worker.config;

import com.example.cdc.common.snapshot.HttpS3BlobFetcher;
import com.example.cdc.common.snapshot.S3BlobFetcher;
import com.example.cdc.common.snapshot.SnapshotCache;
import com.example.cdc.common.snapshot.SnapshotHydrator;
import com.example.cdc.common.transform.TEstablecimientoFkCycleTransformer;
import com.example.cdc.common.transform.TForeignKeyResolver;
import com.example.cdc.common.transform.TGrupoFkRewriter;
import com.example.cdc.common.transform.TMatriculaConsolidator;
import com.example.cdc.common.transform.TPeriodoAcademicoConfigSplitter;
import com.example.cdc.common.transform.TSedeUsuarioPkTransformer;
import com.example.cdc.worker.oracle.OracleJdbcWriter;
import com.example.cdc.worker.transform.TArchivoBlobDropper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.Map;

/**
 * Wires the L4-L6 reverse-sync transformers constructed in Phase 2 of the
 * retrocompatibilidad plan. Until this configuration was added the
 * Phase 2 transformers could not be resolved by Spring at runtime — they
 * are plain classes (no {@code @Component}) that require constructor
 * injection of the {@link SnapshotCache} hydrated at boot by
 * {@link SnapshotHydrator}.
 *
 * <p>Beans produced:
 * <ul>
 *   <li>{@link HttpS3BlobFetcher} — JDK HttpClient-based S3 fetcher used
 *       by {@link TArchivoBlobDropper} for {@code tarchivo} BLOBs.
 *       Request timeout and payload size cap come from
 *       {@code cdc.s3.timeout-ms} / {@code cdc.s3.max-bytes}.</li>
 *   <li>{@link SnapshotCache} — single shared, hydrated at startup.
 *       Hydration is failure-tolerant: a fully-failed hydrate yields
 *       {@link SnapshotCache#empty()} so the transformers can still
 *       instantiate (they WARN + skip on the first cache miss).</li>
 *   <li>{@link TMatriculaConsolidator} — L6 consolidator.</li>
 *   <li>{@link TEstablecimientoFkCycleTransformer} — L4 FK cycle resolver.
 *       Stateful (pending FKs queue), so it MUST be a singleton. Beans
 *       are singletons by default.</li>
 *   <li>{@link TSedeUsuarioPkTransformer} — composite-PK converter for L4.
 *       Carries the {@code @Component}-scanned class, so the redundant
 *       annotation was removed from the source file when this config
 *       landed to avoid duplicate bean definitions.</li>
 *   <li>{@link TPeriodoAcademicoConfigSplitter} — L5 split inverter.</li>
 *   <li>{@link TGrupoFkRewriter} — L5 catalog FK rewriter.</li>
 *   <li>{@link TArchivoBlobDropper} — L4 BLOB streaming writer.</li>
 * </ul>
 *
 * <p>No {@code @ConditionalOnProperty} on these beans: the transformers
 * are inert until {@code OracleReverseStage} routes an event through
 * them, and {@code OracleReverseStage} itself is already gated by
 * {@code cdc.destinations.oracle.enabled} upstream in the pipeline.
 */
@Configuration
public class RetrocompatConfig {

    /**
     * Default S3 fetch timeout (30 s) — picked well above the longest
     * expected slow fetch (multi-MB PDFs) but well below the worker's
     * AMQP heartbeat interval so a hung blob never wedges the consumer.
     */
    private static final int DEFAULT_S3_TIMEOUT_MS = 30_000;

    /**
     * Default S3 payload cap (100 MiB) — mirrors
     * {@code OracleJdbcWriter.mergeWithBlob} semantics: anything above
     * this is rejected by the bounded stream before it can saturate the
     * JVM heap.
     */
    private static final long DEFAULT_S3_MAX_BYTES = 100L * 1024 * 1024;

    @Bean
    public HttpS3BlobFetcher httpS3BlobFetcher(
            @Value("${cdc.s3.timeout-ms:" + DEFAULT_S3_TIMEOUT_MS + "}") int timeoutMs,
            @Value("${cdc.s3.max-bytes:" + DEFAULT_S3_MAX_BYTES + "}") long maxBytes) {
        return new HttpS3BlobFetcher(timeoutMs, maxBytes);
    }

    /**
     * Single, shared {@link S3BlobFetcher} alias so callers (notably
     * {@link TArchivoBlobDropper}) can be wired against the interface
     * rather than the JDK-HTTP implementation. Lives here, not in
     * {@code cdc-common}, because the worker is the only consumer.
     *
     * <p>{@code @Primary} breaks the ambiguity when both the concrete
     * {@link HttpS3BlobFetcher} bean AND this interface alias qualify
     * for the same injection point (the concrete bean is also an
     * {@link S3BlobFetcher} by inheritance, so without {@code @Primary}
     * Spring reports "found 2 candidates" at startup).
     */
    @Bean
    @org.springframework.context.annotation.Primary
    public S3BlobFetcher s3BlobFetcher(HttpS3BlobFetcher httpS3BlobFetcher) {
        return httpS3BlobFetcher;
    }

    @Bean
    public SnapshotCache snapshotCache(SnapshotHydrator hydrator) {
        return hydrator.hydrate();
    }

    @Bean
    public TMatriculaConsolidator matriculaConsolidator(SnapshotCache cache) {
        return new TMatriculaConsolidator(cache);
    }

    @Bean
    public TEstablecimientoFkCycleTransformer establecimientoFkCycleTransformer() {
        return new TEstablecimientoFkCycleTransformer();
    }

    @Bean
    public TSedeUsuarioPkTransformer sedeUsuarioPkTransformer(SnapshotCache cache) {
        return new TSedeUsuarioPkTransformer(cache);
    }

    @Bean
    public TPeriodoAcademicoConfigSplitter periodoAcademicoConfigSplitter(SnapshotCache cache) {
        return new TPeriodoAcademicoConfigSplitter(cache);
    }

    @Bean
    public TGrupoFkRewriter grupoFkRewriter(SnapshotCache cache) {
        return new TGrupoFkRewriter(cache);
    }

    @Bean
    public TArchivoBlobDropper archivoBlobDropper(S3BlobFetcher fetcher,
                                                 OracleJdbcWriter writer,
                                                 @Value("${cdc.s3.max-bytes:" + DEFAULT_S3_MAX_BYTES + "}") long maxBytes) {
        return new TArchivoBlobDropper(fetcher, writer, maxBytes);
    }

    /**
     * Resolves {@code FK_TLV_<X>} codigos → Oracle PKs for every bucket-A
     * table routed through the generic YAML chain. Wired into
     * {@code table-routing.yaml} alongside {@code ColumnRenamer +
     * TypeMapper}; not consulted by Phase 2 transformers, which keep their
     * existing narrow resolver accessors.
     *
     * <p>Overrides are sourced from {@code transforms/fk-resolver.yaml} on
     * the worker classpath; the file maps the small set of column names
     * whose suffix rule does not name a real TLISTA_VALOR categoria
     * (e.g. {@code FK_TLV_FORMATO_CALIFICACION_ACT} →
     * {@code categoria=FORMATO_CALIFICACION}).
     */
    @Bean
    public TForeignKeyResolver foreignKeyResolver(SnapshotCache cache) throws java.io.IOException {
        org.yaml.snakeyaml.Yaml yaml = new org.yaml.snakeyaml.Yaml();
        try (java.io.InputStream in = new org.springframework.core.io.ClassPathResource(
                "transforms/fk-resolver.yaml").getInputStream()) {
            @SuppressWarnings("unchecked")
            Map<String, Object> root = yaml.load(in);
            @SuppressWarnings("unchecked")
            Map<String, String> overrides =
                (Map<String, String>) root.getOrDefault("overrides", Map.of());
            return new TForeignKeyResolver(cache, overrides);
        }
    }
}
