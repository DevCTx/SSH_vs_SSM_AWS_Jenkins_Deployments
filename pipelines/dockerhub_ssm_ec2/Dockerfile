FROM amazoncorretto:17-alpine-jdk

WORKDIR /app

EXPOSE 3080

COPY ./target/java-maven-app-*.jar app.jar

CMD ["java", "-jar", "app.jar"]