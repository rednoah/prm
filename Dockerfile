FROM ruby:latest

MAINTAINER Reinhard Pointner <rednoah@filebot.net>

COPY . /prm

ENTRYPOINT ["/prm/bin/prm"]
