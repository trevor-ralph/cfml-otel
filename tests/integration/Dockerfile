# Integration-test runner: `docker compose run --rm tests` from dev/ (see dev/docker-compose.yml).
FROM python:3.13.18-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /tests
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements.txt
COPY *.py pytest.ini ./

# -rA: list every outcome (pass, xfail, skip) at the end; JUnit XML for CI
ENTRYPOINT ["pytest", "-rA", "--junitxml=/results/junit.xml"]
