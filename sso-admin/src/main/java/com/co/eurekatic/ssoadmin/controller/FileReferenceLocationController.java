package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.ssoadmin.dto.FileReferenceLocationRequest;
import com.co.eurekatic.ssoadmin.dto.FileReferenceLocationResponse;
import com.co.eurekatic.ssoadmin.service.FileReferenceLocationAdminService;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * V-file-reference-admin — nivel-admin-sso para inspeccionar y
 * corregir a mano una fila de {@code public.file_reference_location}
 * (V143/V147), el registro global que le dice a file-service en qué
 * {@code schema.tabla} vive cada {@code pk_tarchivo}. Ver {@code
 * FileReferenceLocationAdminService} para el porqué -- nace del caso
 * real de {@code pk_tarchivo=490026}, huérfano tras un despliegue a
 * medio ciclo, que dejaba 404 el visor de file-service aunque el
 * archivo y su fila de negocio existieran perfectamente.
 *
 * <p>Cae bajo la misma regla catch-all que el resto de este módulo
 * ({@code ssoAdminAccessManager}): necesita una fila {@code
 * endpoint} y un {@code role_endpoint} -- ver {@code
 * postgres/migrations/V154__file_reference_location_admin_endpoint.sql}.
 */
@RestController
@RequestMapping("/file-references")
public class FileReferenceLocationController {

    private final FileReferenceLocationAdminService service;

    public FileReferenceLocationController(FileReferenceLocationAdminService service) {
        this.service = service;
    }

    @GetMapping("/{pkTarchivo}")
    public FileReferenceLocationResponse find(@PathVariable long pkTarchivo) {
        return service.find(pkTarchivo);
    }

    @PutMapping("/{pkTarchivo}")
    public FileReferenceLocationResponse upsert(
            @PathVariable long pkTarchivo,
            @Valid @RequestBody FileReferenceLocationRequest req) {
        return service.upsert(pkTarchivo, req);
    }
}
