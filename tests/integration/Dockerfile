# Integration-test runner: `docker compose run --rm tests` from dev/ (see dev/docker-compose.yml).
FROM python:3.15.2-slim-trixie@sha256:63bb298d2b7b88f176f51b5189f54ce6535c997682ea70885d2132f5d473a8a5

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /tests
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements.txt
COPY *.py pytest.ini ./

# -rA: list every outcome (pass, xfail, skip) at the end; JUnit XML for CI
ENTRYPOINT ["pytest", "-rA", "--junitxml=/results/junit.xml"]
