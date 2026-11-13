FROM python:3.12.12-slim-bookworm@sha256:593bd06efe90efa80dc4eee3948be7c0fde4134606dd40d8dd8dbcade98e669c
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN python -m pip install --no-cache-dir --require-hashes -r requirements.txt \
    && useradd --uid 10001 --create-home demo
COPY common.py calculator.py catalog.py assertion_client.py jwt_tool.py ./
USER 10001
EXPOSE 8000
CMD ["python", "calculator.py"]
