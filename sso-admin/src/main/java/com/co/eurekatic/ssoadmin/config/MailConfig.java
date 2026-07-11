package com.co.eurekatic.ssoadmin.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Configuration;

/**
 * Binds the {@link EmailProperties} record. The
 * {@code JavaMailSender} and Freemarker {@code Configuration}
 * are auto-configured by Spring Boot from {@code spring.mail.*}
 * and {@code spring.freemarker.*} respectively — no extra beans
 * needed here.
 */
@Configuration
@EnableConfigurationProperties(EmailProperties.class)
public class MailConfig {
}
