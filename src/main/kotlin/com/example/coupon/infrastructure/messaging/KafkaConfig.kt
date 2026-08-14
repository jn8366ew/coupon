package com.example.coupon.infrastructure.messaging

import org.apache.kafka.clients.admin.AdminClientConfig
import org.apache.kafka.clients.consumer.ConsumerConfig
import org.apache.kafka.clients.producer.ProducerConfig
import org.apache.kafka.common.serialization.StringDeserializer
import org.apache.kafka.common.serialization.StringSerializer
import org.springframework.beans.factory.annotation.Value
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.kafka.annotation.EnableKafka
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory
import org.springframework.kafka.core.ConsumerFactory
import org.springframework.kafka.core.DefaultKafkaConsumerFactory
import org.springframework.kafka.core.DefaultKafkaProducerFactory
import org.springframework.kafka.core.KafkaAdmin
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.kafka.core.ProducerFactory
import org.springframework.kafka.listener.ContainerProperties
import org.springframework.kafka.listener.DefaultErrorHandler
import org.springframework.kafka.support.JacksonMapperUtils
import org.springframework.kafka.support.serializer.ErrorHandlingDeserializer
import org.springframework.kafka.support.serializer.JacksonJsonDeserializer
import org.springframework.kafka.support.serializer.JacksonJsonSerializer
import tools.jackson.databind.json.JsonMapper

@Configuration
@EnableKafka
class KafkaConfig(
    @Value("\${spring.kafka.bootstrap-servers}") private val bootstrapServers: String,
) {

    private val jsonMapper: JsonMapper = JacksonMapperUtils.enhancedJsonMapper()

    /**
     * 이 프로젝트에는 Kafka 자동설정이 없다. build.gradle.kts 가 spring-boot-starter-kafka 가 아니라
     * org.springframework.kafka:spring-kafka 를 직접 넣었고, Boot 4 부터 자동설정은 기술별 모듈
     * (spring-boot-kafka)에 있어 starter 로만 딸려온다. 그래서 KafkaAdmin 도 없었고,
     * KafkaTopicConfig 의 NewTopic 빈은 아무 일도 하지 않고 있었다 — 토픽은 브로커의
     * auto-create 로 생겼고 DLT 는 아무도 안 건드려서 아예 없었다.
     *
     * 팩토리를 전부 손으로 만드는 이 클래스의 방식대로 admin 도 여기서 만든다.
     */
    @Bean
    fun kafkaAdmin(): KafkaAdmin =
        KafkaAdmin(mapOf<String, Any>(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG to bootstrapServers))

    @Bean
    fun producerFactory(): ProducerFactory<String, Any> {
        val props = mapOf<String, Any>(
            ProducerConfig.BOOTSTRAP_SERVERS_CONFIG to bootstrapServers,
            ProducerConfig.ACKS_CONFIG to "1",
            // 기본값이 60초다. 브로커가 죽으면 발급 요청마다 Tomcat 스레드가 60초씩 묶여
            // 앱 전체가 같이 멈춘다. 실패는 빨리 드러나야 보상도 빨리 돈다.
            ProducerConfig.MAX_BLOCK_MS_CONFIG to 3_000,
        )
        return DefaultKafkaProducerFactory(props, StringSerializer(), JacksonJsonSerializer<Any>(jsonMapper))
    }

    @Bean
    fun kafkaTemplate(producerFactory: ProducerFactory<String, Any>): KafkaTemplate<String, Any> =
        KafkaTemplate(producerFactory)

    @Bean
    fun consumerFactory(): ConsumerFactory<String, Any> {
        val props = mapOf<String, Any>(
            ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG to bootstrapServers,
            ConsumerConfig.GROUP_ID_CONFIG to IssuanceTopics.CONSUMER_GROUP,
            ConsumerConfig.AUTO_OFFSET_RESET_CONFIG to "earliest",
        )
        val jsonDelegate = JacksonJsonDeserializer(IssuanceRequested::class.java, jsonMapper).apply {
            addTrustedPackages("com.example.coupon.infrastructure.messaging")
        }
        @Suppress("UNCHECKED_CAST")
        val valueDeserializer = ErrorHandlingDeserializer(jsonDelegate) as ErrorHandlingDeserializer<Any>
        return DefaultKafkaConsumerFactory(props, StringDeserializer(), valueDeserializer)
    }

    @Bean
    fun kafkaListenerContainerFactory(
        consumerFactory: ConsumerFactory<String, Any>,
        errorHandler: DefaultErrorHandler,
    ): ConcurrentKafkaListenerContainerFactory<String, Any> {
        val factory = ConcurrentKafkaListenerContainerFactory<String, Any>()
        factory.setConsumerFactory(consumerFactory)
        factory.setCommonErrorHandler(errorHandler)
        return factory
    }
}