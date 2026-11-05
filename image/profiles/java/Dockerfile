# Java 21 (Eclipse Temurin JDK) and Maven; Gradle projects use their gradlew wrapper
#
#   claude-ide-box preset java on
# The JVM ignores HTTPS_PROXY, so Maven and every JVM (Gradle included) are
# pointed at the proxy through the "egress-proxy" host entry that each
# container gets.
ARG BASE_IMAGE=claude-ide-box/base:latest
ARG JDK_IMAGE=eclipse-temurin:21-jdk
ARG MAVEN_IMAGE=maven:3-eclipse-temurin-21
FROM ${JDK_IMAGE} AS jdk
FROM ${MAVEN_IMAGE} AS maven

FROM ${BASE_IMAGE}
USER root
# Root steps must not leave files in the home directory (see setup).
ENV HOME=/root
COPY --from=jdk /opt/java/openjdk /opt/java/openjdk
COPY --from=maven /usr/share/maven /usr/share/maven
COPY maven-settings.xml /usr/share/maven/conf/settings.xml
RUN ln -s /usr/share/maven/bin/mvn /usr/local/bin/mvn
ENV JAVA_HOME=/opt/java/openjdk \
    MAVEN_HOME=/usr/share/maven \
    GRADLE_USER_HOME=/home/claude/.gradle \
    JAVA_TOOL_OPTIONS="-Dhttps.proxyHost=egress-proxy -Dhttps.proxyPort=3128 -Dhttp.proxyHost=egress-proxy -Dhttp.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1" \
    PATH=/opt/java/openjdk/bin:$PATH
RUN java -version && mvn -v
ENV HOME=/home/claude
USER claude
