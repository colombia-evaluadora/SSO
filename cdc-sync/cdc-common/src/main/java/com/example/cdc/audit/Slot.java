package com.example.cdc.audit;

/**
 * Named JSON slot in the audit_log.fila_new / fila_old columns.
 * Ordered to match spec §5 rule priority: PK first, then FK (the only
 * non-scalar slot), then dates, then booleans, then numeric, then text.
 */
public enum Slot {
    PK_T("pk_t"),
    CODIGO("codigo"),
    VALOR("valor"),
    NOMBRE("nombre"),
    FECHA("fecha"),
    FECHA_TS("fecha_ts"),
    NUMERO("numero"),
    DECIMAL("decimal"),
    TEXTO("texto"),
    BOOLEANO_SN("booleano_sn"),
    PADRE_ID_JSON("padre_id_json"),
    NONE("none");

    private final String code;

    Slot(String code) {
        this.code = code;
    }

    public String code() {
        return code;
    }
}
