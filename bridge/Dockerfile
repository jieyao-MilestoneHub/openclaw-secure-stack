FROM docker:27-cli
RUN apk add --no-cache python3
COPY server.py /server.py
RUN chmod 0555 /server.py
EXPOSE 8005
USER root
CMD ["python3", "/server.py"]
