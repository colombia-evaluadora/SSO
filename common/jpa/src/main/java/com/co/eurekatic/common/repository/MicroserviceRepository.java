package com.co.eurekatic.common.repository;

import com.co.eurekatic.common.entity.Microservice;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

/**
 * Spring Data JPA repository for {@link Microservice}.
 *
 * <p>Most queries are simple {@code findAll} / {@code findById}
 * — the controller layer needs a method to look up by
 * {@code serviceId} (the natural key from the legacy
 * {@code getMicroservice?serviceId=…} endpoint) and an
 * existence check used for duplicate-rejection in
 * {@code createMicroservice}.
 *
 * <p>{@code findByInstanceName} / {@code existsByInstanceName}
 * drive the QUERY-kind provisioner flow — instance names are
 * optional and only QUERY rows have them, so the DB partial
 * index keeps both lookups fast even when the table grows.
 */
@Repository
public interface MicroserviceRepository extends JpaRepository<Microservice, Long> {

    Optional<Microservice> findByServiceId(String serviceId);

    boolean existsByServiceId(String serviceId);

    Optional<Microservice> findByInstanceName(String instanceName);

    boolean existsByInstanceName(String instanceName);

    /**
     * Microservices whose {@code id_app} FK points at the
     * given app — used by the {@code AppService} when
     * listing a single app's services.
     */
    List<Microservice> findAllByApp_Id(Long appId);

    /**
     * V27 — every microservice that has a non-null
     * {@code request_uri} (the gateway path prefix). Used
     * by {@code InternalGatewayController} to publish the
     * route table to {@code api-gateway}'s
     * {@code CatalogRoutesRefresher}.
     *
     * <p>Spring Data derives the query from the method
     * name ({@code WHERE request_uri IS NOT NULL}). The
     * catalog table is small (hundreds of rows tops), so
     * an in-memory scan is fine; add a derived index on
     * {@code request_uri} only if this becomes hot.
     */
    List<Microservice> findAllByRequestUriIsNotNull();
}
