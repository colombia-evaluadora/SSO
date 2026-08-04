package com.example.cdc.worker.config;

import com.example.cdc.audit.ColumnTypeRegistry;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class ColumnTypeRegistryConfig {

    @Bean
    public ColumnTypeRegistry columnTypeRegistry() {
        return ColumnTypeRegistry.loadFromClasspath("column-types.json");
    }
}
