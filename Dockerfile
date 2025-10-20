FROM debian:stable
LABEL authors="jordan"
RUN apt update && apt upgrade -y
RUN apt install -y procps
COPY . .
RUN chmod +x ./server-stats.sh