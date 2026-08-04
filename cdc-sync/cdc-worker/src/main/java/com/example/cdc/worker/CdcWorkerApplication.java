package com.example.cdc.worker;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication(scanBasePackages = "com.example.cdc")
public class CdcWorkerApplication {
    public static void main(String[] args) {
        SpringApplication.run(CdcWorkerApplication.class, args);
    }
}
