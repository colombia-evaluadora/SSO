package com.example.cdc.common.transform;

public record OperationContext(
        String pgTable,
        String oracleTable,
        String oracleSchema,
        String pkColumn,
        boolean isInsert,
        boolean isUpdate,
        boolean isDelete
) {}