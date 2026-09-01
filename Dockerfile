# ═══════════════════════════════════════════════════════════════
#  IBSng — built from source, containerized
#
#  Base: Debian jessie (PHP 5.6). This is deliberate: IBSng (2010) was
#  written for PHP5 and never updated. On PHP7 dozens of removed
#  features (ereg/split, &new, reserved class names Error/Generator,
#  dl()) break the admin panel one at a time. On PHP5.6 — the actual
#  version IBSng targets — almost none of that applies; the only real
#  PHP-side patch left is the "Generator" class name collision (PHP
#  5.5+ added its own final Generator class for `yield` support).
#
#  jessie is long EOL, so apt is pointed at archive.debian.org with
#  signature checking disabled (the archive's keys have expired).
# ═══════════════════════════════════════════════════════════════
FROM debian:jessie-slim

ENV DEBIAN_FRONTEND=noninteractive

# point apt at the Debian archive (jessie is EOL); jessie-slim's default
# sources.list format doesn't map cleanly onto archive.debian.org's
# layout, so it's replaced outright rather than sed-patched
RUN printf 'deb [trusted=yes] http://archive.debian.org/debian jessie main\ndeb [trusted=yes] http://archive.debian.org/debian-security jessie/updates main\n' > /etc/apt/sources.list \
    && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid \
    && echo 'Acquire::AllowInsecureRepositories "true";' >> /etc/apt/apt.conf.d/99no-check-valid \
    && apt-get update

# debian:jessie-slim strips /usr/share/man to save space, but
# postgresql-client's postinst script assumes these dirs exist (to
# symlink man pages into them) and fails otherwise — recreate them first
RUN mkdir -p /usr/share/man/man1 /usr/share/man/man7

# apache2 + native PHP 5.6 — the version IBSng was actually written for
RUN apt-get install -y --no-install-recommends \
        apache2 \
        libapache2-mod-php5 \
        php5-cli php5-pgsql php5-cgi \
        postgresql postgresql-contrib \
        python2.7 \
        python-pygresql \
        python-openssl \
        locales \
        expect ncurses-base \
        wget bzip2 ca-certificates \
        procps net-tools iproute2 sudo \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    && update-locale LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# the postgresql package auto-creates a default cluster during install —
# wipe it so the image ships with a clean, empty /var/lib/postgresql and
# our entrypoint does a proper initdb on first container run
RUN (pg_dropcluster --stop 9.4 main || true) \
    && rm -rf /var/lib/postgresql/9.4 \
    && mkdir -p /var/lib/postgresql \
    && chown postgres:postgres /var/lib/postgresql

# ── compatibility shim: tolerate IBSng's classic 7-arg PyGreSQL
# connect() call. Tries the real call FIRST and only trims the legacy
# unused "tty" argument on a genuine TypeError, so this is safe whether
# or not the bundled PyGreSQL version already accepts 7 args natively. ──
RUN python2.7 -c "import pg; print(pg.__file__)" \
    && PG_PY=$(python2.7 -c "import pg; print(pg.__file__.replace('.pyc','.py'))") \
    && printf '\n# --- IBSng compatibility shim: tolerate legacy 7-arg connect() ---\n_ibsng_orig_connect = connect\ndef connect(*args, **kwargs):\n    try:\n        return _ibsng_orig_connect(*args, **kwargs)\n    except TypeError:\n        if len(args) == 7:\n            return _ibsng_orig_connect(*(args[:4] + args[5:]), **kwargs)\n        raise\n# --- end shim ---\n' >> "$PG_PY" \
    && rm -f "${PG_PY}c"

# fetch IBSng source. Default points at the SourceForge project page the
# user linked. Override with --build-arg IBSNG_URL=<direct .tar.bz2 link>
# if SourceForge's "latest" redirect ever points somewhere unexpected.
ARG IBSNG_URL=https://sourceforge.net/projects/ibsng/files/latest/download
RUN wget -L -O /tmp/ibsng.tar.bz2 "$IBSNG_URL" \
    && mkdir -p /usr/local/IBSng \
    && tar -xvjf /tmp/ibsng.tar.bz2 -C /tmp \
    && SRC_DIR=$(find /tmp -maxdepth 1 -iname 'IBSng*' -type d | head -n1) \
    && cp -a "$SRC_DIR"/. /usr/local/IBSng/ \
    && rm -rf /tmp/ibsng.tar.bz2 "$SRC_DIR"

# ── compatibility patches ──
# 1) missing utf-8 source declarations some Python2 builds require
# 2) "Generator" class name collides with PHP 5.5+'s own final
#    Generator class (used for `yield`) — rename IBSng's own class
# 3) Smarty's compiled-template cache dir must be writable by Apache
#    (www-data), or pages render as a silent, error-free blank page
RUN sed -i '1i #coding:utf-8' /usr/local/IBSng/core/lib/IPy.py \
    && sed -i '1i #coding:utf-8' /usr/local/IBSng/core/lib/mschap/des_c.py \
    && chmod +x /usr/local/IBSng/scripts/setup.py /usr/local/IBSng/ibs.py \
    && mkdir -p /var/log/IBSng \
    && chown -R www-data:www-data /var/log/IBSng \
    && chown -R www-data:www-data /usr/local/IBSng/interface/smarty/templates_c \
    && chmod -R 775 /usr/local/IBSng/interface/smarty/templates_c \
    && find /usr/local/IBSng/interface -name '*.php' -print0 | xargs -0 sed -i \
        -e 's/class Generator\b/class IBSngGenerator/g' \
        -e 's/extends Generator\b/extends IBSngGenerator/g' \
        -e 's/new Generator(/new IBSngGenerator(/g' \
        -e 's/instanceof Generator\b/instanceof IBSngGenerator/g'

COPY files/ibsng-apache.conf /etc/apache2/conf-available/ibsng.conf
RUN a2enconf ibsng \
    && a2enmod php5 rewrite || true

COPY files/setup.exp /usr/local/IBSng/scripts/setup.exp
COPY files/entrypoint.sh /entrypoint.sh
COPY files/unattended-answers.txt /usr/local/IBSng/scripts/unattended-answers.txt
RUN chmod +x /entrypoint.sh /usr/local/IBSng/scripts/setup.exp

# Web (admin panel), XML-RPC API, RADIUS auth, RADIUS accounting
EXPOSE 80/tcp 1235/tcp 1812/udp 1813/udp

# Postgres data lives here so a named volume makes it persistent
VOLUME ["/var/lib/postgresql"]

ENTRYPOINT ["/entrypoint.sh"]
