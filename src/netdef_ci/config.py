#  SPDX-License-Identifier: BSD-2-Clause
#
#  config.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Environment-driven configuration (variables, `.env` and an optional `~/.netrc` fallback for credentials)."""

from __future__ import annotations

import netrc
import tomllib
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


@dataclass(frozen=True)
class GitHubAppConfig:
    """One entry of the `github_apps` list (`login`, `cert`, `repo`)."""

    login: str
    cert: str
    repo: str | None = None


@dataclass(frozen=True)
class Credentials:
    username: str
    password: str


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore", populate_by_name=True)

    env: Literal["development", "production", "test"] = Field("development", alias="NETDEF_ENV")
    debug: bool = Field(False, alias="DEBUG")
    log_dir: str | None = Field(None, alias="LOG_DIR")
    # `github_http.log` (one line per GitHub API call) rotates at this size and keeps this many files in total;
    # files default to 5 in production and 1 elsewhere.
    github_http_log_max_bytes: int = Field(1024**3, alias="GITHUB_HTTP_LOG_MAX_BYTES", ge=1024)
    github_http_log_files: int | None = Field(None, alias="GITHUB_HTTP_LOG_FILES", ge=1)

    database_url: str = Field(
        "postgresql+psycopg://postgres:postgres@localhost:5432/githubruns-dev", alias="DATABASE_URL"
    )
    db_pool_size: int = Field(10, alias="DB_POOL_SIZE")

    # --- webhook / callback authentication -------------------------------------------------
    webhook_secret: SecretStr = Field(SecretStr(""), alias="WEBHOOK_SECRET")
    webhook_dedupe_ttl_seconds: int = Field(0, alias="WEBHOOK_DEDUPE_TTL_SECONDS", ge=0)
    metrics_username: str | None = Field(None, alias="METRICS_USERNAME")
    metrics_password: SecretStr | None = Field(None, alias="METRICS_PASSWORD")

    # --- GitHub -------------------------------------------------------------------------------
    github_apps_file: str | None = Field(None, alias="GITHUB_APPS_FILE")
    github_api_url: str = Field("https://api.github.com", alias="GITHUB_API_URL")
    github_app_name: str = Field("NetDEF CI Hook", alias="GITHUB_APP_NAME")
    github_max_retries: int = Field(3, alias="GITHUB_MAX_RETRIES", ge=0, le=10)

    # --- Bamboo -------------------------------------------------------------------------------
    bamboo_base_url: str = Field("https://127.0.0.1", alias="BAMBOO_BASE_URL")
    bamboo_verify_tls: bool = Field(False, alias="BAMBOO_VERIFY_TLS")
    bamboo_username: str | None = Field(None, alias="BAMBOO_USERNAME")
    bamboo_password: SecretStr | None = Field(None, alias="BAMBOO_PASSWORD")
    bamboo_netrc_machine: str = Field("ci1.netdef.org", alias="BAMBOO_NETRC_MACHINE")
    ci_url: str = Field("ci1.netdef.org", alias="CI_URL")
    multi_plan: bool = Field(False, alias="MULTI_PLAN")

    # --- Slack bot ----------------------------------------------------------------------------
    slack_bot_url: str | None = Field(None, alias="SLACK_BOT_URL")
    slack_bot_username: str | None = Field(None, alias="SLACK_BOT_USERNAME")
    slack_bot_password: SecretStr | None = Field(None, alias="SLACK_BOT_PASSWORD")
    slack_bot_netrc_machine: str = Field("slack_bot.netdef.org", alias="SLACK_BOT_NETRC_MACHINE")
    slack_bot_verify_tls: bool = Field(True, alias="SLACK_BOT_VERIFY_TLS")

    # --- HTTP clients -------------------------------------------------------------------------
    http_timeout_seconds: float = Field(30.0, alias="HTTP_TIMEOUT_SECONDS", gt=0)

    # --- background jobs (5 attempts, 5 min lock, 5 s polling) ------------
    job_max_attempts: int = Field(5, alias="JOB_MAX_ATTEMPTS", ge=1)
    job_max_run_time_seconds: int = Field(300, alias="JOB_MAX_RUN_TIME_SECONDS", ge=1)
    job_sleep_delay_seconds: float = Field(5.0, alias="JOB_SLEEP_DELAY_SECONDS", gt=0)
    status_debounce_seconds: int = Field(30, alias="STATUS_DEBOUNCE_SECONDS", ge=0)
    create_execution_delay_seconds: int = Field(5, alias="CREATE_EXECUTION_DELAY_SECONDS", ge=0)
    rerun_delay_seconds: int = Field(1, alias="RERUN_DELAY_SECONDS", ge=0)
    running_plan_wait_seconds: int = Field(60, alias="RUNNING_PLAN_WAIT_SECONDS", ge=0)
    running_plan_poll_seconds: float = Field(3.0, alias="RUNNING_PLAN_POLL_SECONDS", gt=0)
    timeout_check_minutes: int = Field(10, alias="TIMEOUT_CHECK_MINUTES", ge=1)
    timeout_hang_hours: int = Field(2, alias="TIMEOUT_HANG_HOURS", ge=1)
    # How long a new execution waits for Bamboo to confirm that the previous one of the same PR stopped.
    execution_cancel_wait_max_seconds: int = Field(60, alias="EXECUTION_CANCEL_WAIT_MAX_SECONDS", ge=0)
    execution_cancel_poll_seconds: float = Field(5.0, alias="EXECUTION_CANCEL_POLL_SECONDS", gt=0)

    web_workers: int = Field(1, alias="WEB_WORKERS", ge=1)  # reported by the puma_workers_total metric

    # --- metrics ------------------------------------------------------------------------------
    prometheus_multiproc_dir: str = Field("/tmp/prometheus_metrics", alias="PROMETHEUS_MULTIPROC_DIR")  # noqa: S108
    ci_metrics_window_hours: int = Field(24, alias="CI_METRICS_WINDOW_HOURS", ge=1)

    @field_validator("ci_url")
    @classmethod
    def _strip_scheme(cls, value: str) -> str:
        # Links are built as "https://<ci_url>/browse/..."; accept both "host" and "https://host".
        for prefix in ("https://", "http://"):
            if value.startswith(prefix):
                value = value[len(prefix) :]
        return value.rstrip("/")

    # ------------------------------------------------------------------------------------------
    def github_apps(self) -> list[GitHubAppConfig]:
        """Load the GitHub App list from the TOML file (`[[github_apps]]` with login/cert/repo)."""
        if not self.github_apps_file:
            return []
        data = tomllib.loads(Path(self.github_apps_file).read_text(encoding="utf-8"))
        apps = []
        for entry in data.get("github_apps", []):
            apps.append(GitHubAppConfig(login=str(entry["login"]), cert=str(entry["cert"]), repo=entry.get("repo")))
        return apps

    def bamboo_credentials(self) -> Credentials | None:
        return _credentials(self.bamboo_username, self.bamboo_password, self.bamboo_netrc_machine)

    def slack_credentials(self) -> Credentials | None:
        return _credentials(self.slack_bot_username, self.slack_bot_password, self.slack_bot_netrc_machine)

    def browse_url(self, reference: str | None) -> str:
        return f"https://{self.ci_url}/browse/{reference}"


def _credentials(username: str | None, password: SecretStr | None, machine: str) -> Credentials | None:
    if username and password is not None:
        return Credentials(username, password.get_secret_value())
    try:
        entry = netrc.netrc().authenticators(machine)
    except FileNotFoundError, netrc.NetrcParseError, OSError:
        return None
    if entry is None:
        return None
    login, _account, passwd = entry
    return Credentials(login or "", passwd or "")


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]


def reset_settings_cache() -> None:
    get_settings.cache_clear()
