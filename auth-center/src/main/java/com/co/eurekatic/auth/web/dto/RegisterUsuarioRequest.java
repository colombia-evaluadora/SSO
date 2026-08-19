package com.co.eurekatic.auth.web.dto;

import com.co.eurekatic.common.security.PasswordPolicy;
import jakarta.validation.constraints.*;

import java.time.LocalDate;

public record RegisterUsuarioRequest(
    @NotBlank @Email @Size(max = 200) String email,
    @NotBlank @Size(max = 200) String fullName,
    @NotBlank @Size(min = PasswordPolicy.MIN_LENGTH, max = PasswordPolicy.MAX_LENGTH) String password,
    @NotBlank @Size(max = 30) String identificacion,
    @NotBlank @Size(max = 40) String primerNombre,
    @NotBlank @Size(max = 40) String primerApellido,
    @Past LocalDate fechaNacimiento,
    @Positive Long fkTlvTipoDocumento,
    @Positive Long fkTlvGenero,
    @Size(max = 40) String segundoNombre,
    @Size(max = 40) String segundoApellido,
    @Size(max = 30) String telefono,
    @Email @Size(max = 120) String correoElectronico,
    @Positive Long fkTarchivoFoto,
    @Size(max = 2) String visado
) {}
