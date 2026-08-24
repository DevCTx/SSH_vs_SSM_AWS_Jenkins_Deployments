# MyApp

An ultra-minimalist `Spring Boot web application` (Java 17, Maven) that does nothing but display the message `"Welcome to my Java app"` on the screen.

## Stack

- Spring Boot 3.5.5 (`spring-boot-starter-web`)
- Maven
- Static page: `index.html`

## Run

```bash
mvn spring-boot:run
```

App available at: `http://localhost:3080`

## Build

```bash
mvn clean package
java -jar target/my-app-1.0.jar
```

## Config

Port set in `application.properties`:

```
server.port=3080
```
