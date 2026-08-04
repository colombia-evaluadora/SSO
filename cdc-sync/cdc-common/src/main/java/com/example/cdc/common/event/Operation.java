package com.example.cdc.common.event;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonValue;

public enum Operation {
    INSERT("c"),
    UPDATE("u"),
    DELETE("d"),
    SNAPSHOT("r"),
    MESSAGE("m");

    private final String code;

    Operation(String code) {
        this.code = code;
    }

    @JsonValue
    public String code() {
        return code;
    }

    @JsonCreator
    public static Operation fromCode(String code) {
        for (Operation op : values()) {
            if (op.code.equals(code)) return op;
        }
        throw new IllegalArgumentException("Unknown op code: " + code);
    }
}
