package com.co.eurekatic.common.repository;

import com.co.eurekatic.common.entity.Microservice;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

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
    java.util.List<Microservice> findAllByApp_Id(Long appId);
}
