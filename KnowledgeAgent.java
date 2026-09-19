/// usr/bin/env jbang "$0" "$@" ; exit $?
//DEPS org.springframework.boot:spring-boot-starter-web:4.1.1
//DEPS org.springframework.ai:spring-ai-starter-model-bedrock-converse:2.0.0
//DEPS org.springframework.ai:spring-ai-starter-vector-store-bedrock-knowledgebase:2.0.0
//DEPS org.springframework.ai:spring-ai-advisors-vector-store:2.0.0

//JAVA_OPTIONS -Dspring.ai.bedrock.aws.region=us-east-1
//JAVA_OPTIONS -Dspring.ai.bedrock.converse.chat.options.model=us.amazon.nova-lite-v1:0

package com.example;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.client.advisor.vectorstore.QuestionAnswerAdvisor;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.*;

@SpringBootApplication
@RestController
public class KnowledgeAgent {

    private final ChatClient chatClient;

    public KnowledgeAgent(ChatClient.Builder builder, VectorStore vectorStore) {
        this.chatClient = builder
                .defaultAdvisors(QuestionAnswerAdvisor.builder(vectorStore).build())
                .build();
    }

    @CrossOrigin(origins = "*")
    @PostMapping("/chat")
    public String chat(@RequestBody String prompt) {
        return chatClient.prompt()
                .user(prompt)
                .call()
                .content();
    }

    public static void main(String[] args) {
        SpringApplication.run(KnowledgeAgent.class, args);
    }
}
