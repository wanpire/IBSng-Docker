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

# apache2 + native PHP 5.6 — the version IBSng was actually written for.
# php5-gd is required for every graph/chart page (RealTime graphs, BW
# graph, Onlines graph, Connection Analysis) — IBSng's jpgraph library
# needs the GD extension to render PNGs. Without it every graph image
# request 200s with a tiny JpGraph error body instead of an image
# ("This PHP installation is not configured with the GD library"),
# which just renders as a broken-image icon in the browser with no
# obvious error anywhere in the admin panel itself.
RUN apt-get install -y --no-install-recommends \
        apache2 \
        libapache2-mod-php5 \
        php5-cli php5-pgsql php5-cgi php5-gd \
        postgresql postgresql-contrib \
        python2.7 \
        python-pygresql \
        python-openssl \
        locales \
        expect ncurses-base \
        wget bzip2 ca-certificates \
        procps net-tools iproute2 sudo \
    && rm -rf /var/lib/apt/lists/*

# IBSng's own error pages actively hide the real cause of a failure (both
# xmlrpc.inc's generic "Can't connect to IBS Core" wrapper and Smarty's
# silent-blank-page behavior), so PHP's own error log is often the only
# place a fatal actually surfaces. Set this explicitly rather than trust
# Debian's packaged default, which points error_log at a path
# (/var/log/php5/error.log) that isn't necessarily writable by www-data
# out of the box. display_errors stays Off — this is a production panel.
# error_log is deliberately appended rather than sed-replaced in place:
# Debian's stock php.ini has TWO commented "Example:" lines for error_log
# (one for a file path, one for syslog) — a blanket sed on that pattern
# turns both into live, duplicate directives. Appending one unambiguous
# line at the end of the file relies on PHP's normal ini behavior (last
# occurrence of a duplicate directive wins) to guarantee a single,
# unambiguous value regardless of what the stock file already contains.
RUN sed -i \
        -e 's/^;\?display_errors\s*=.*/display_errors = Off/' \
        -e 's/^;\?log_errors\s*=.*/log_errors = On/' \
        /etc/php5/apache2/php.ini \
    && echo 'error_log = /var/log/php5/error.log' >> /etc/php5/apache2/php.ini \
    && mkdir -p /var/log/php5 \
    && touch /var/log/php5/error.log \
    && chown -R www-data:www-data /var/log/php5

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
# 4) upstream typo bug (confirmed via `grep -rn "def getLoadedUsersByUsername"`
#    across core/ returning nothing): UserActions.getUserInfoByNormalUsername()
#    calls self.getLoadedUsersByUsername(), a method that has never existed
#    anywhere in IBSng's own source. The real method, defined a few lines
#    above in the same class, is getLoadedUsersByNormalUsername(). NOTE: as
#    of the SourceForge "latest" snapshot this Dockerfile currently pulls,
#    getUserInfoByNormalUsername() itself is not registered with any XML-RPC
#    handler (core/user/user_handler.py's UserHandler only exposes
#    getUserInfo/searchUser/etc, both of which already call the correctly-
#    spelled getLoadedUsersByNormalUsername directly) — so this exact call
#    is currently dead code, not the live cause of a username-search
#    failure on this snapshot. Fixed anyway since it's a genuine bug that
#    would throw AttributeError the moment anything does call it (directly,
#    or in a different IBSng build/version where it may be wired up).
# 5) same class of upstream typo, found by a systematic self.<method>()
#    call/definition cross-reference across all of core/ — two more calls
#    to methods that don't exist anywhere:
#      - ibs_db.py:154 self.getDictWrapperResult() -> real method (line 162,
#        same class) is getDicWrapperResult() (missing "t"). Currently dead:
#        it's only reached via selectQuery(query, result_type=2), and no
#        caller in core/ ever passes result_type=2 — but it would throw
#        AttributeError the moment something does.
#      - rases/portmaster.py:51,75,78 self.__getPortFromOid() -> real method
#        (line 58, same class) is __getPortFromOID() (case mismatch only,
#        so Python treats them as distinct names). This one is LIVE: it's
#        on the periodic online-user/traffic-polling path for any RAS
#        configured with type "PortMaster" (core/ras/ras.py's
#        UpdateUsersRas.updateUserList()/updateInOutBytes(), invoked by the
#        core daemon's periodic-event scheduler). The exception is caught
#        and logged by core/event/periodic_events.py rather than crashing
#        the daemon, so the failure mode is silent: a PortMaster RAS never
#        tracks online users or in/out byte counters, and the only symptom
#        is a steady stream of AttributeErrors in the core daemon's log
#        every polling cycle.
# 6) missing require_once, found by actually exercising Add New User in a
#    browser against a freshly built image (not by static analysis, which
#    can't see this class of bug — it only checks whether a definition
#    exists ANYWHERE in the tree, not whether the calling file's own
#    require chain can reach it). admin/plugins/edit_funcs.php's
#    editUserAssignValues() calls intSetSingleUserInfo(),
#    intShowSingleUserInfoInput(), and intSetSingleUserGroupAttrs() — all
#    three defined in admin/user/user_info_funcs.php, which edit_funcs.php
#    never requires. It happens to work when reached from a page that
#    already required user_info_funcs.php first, but edit_funcs.php's other
#    two callers (add_new_users.php's post-create redirect to plugins/edit.php,
#    and search_user_edit.php's single-user Edit action) don't — reliably
#    reproduced via Add New User with a single user (count=1): fatal error
#    "Call to undefined function intShowSingleUserInfoInput()". Fixed by
#    adding the require, matching the existing cross-directory require
#    convention already used elsewhere in admin/ (relative to the
#    including file's own directory, e.g. add_new_users.php's own
#    `require_once("../plugins/edit_funcs.php")`).
# 7) interface/IBSng/inc/error.php (loaded on every single admin-panel
#    request) unconditionally runs `ini_set("display_errors",1)` — this
#    silently overrides whatever php.ini says (see the log_errors/
#    display_errors/error_log block earlier in this file) on every
#    request, so display_errors was never actually Off in practice.
#    Caught by actually hitting a page that triggers a PHP notice (the
#    pre-existing, deliberately-left-alone `=& new` deprecated syntax in
#    inc/generator/report_generator/csv_report_generator.php — see
#    README) and seeing it rendered straight into the admin UI. Removed
#    the ini_set so php.ini's Off actually takes effect. Also fixed a typo
#    a few lines below it in the same file: errorHandler()'s "don't log
#    deprecated warnings" check compares `$errno!=2048`, but 2048 is
#    E_STRICT, not E_DEPRECATED (8192) — the comment ("//deprecated
#    warnings") makes the intent clear, so corrected the constant. Both
#    are genuine bugs in IBSng's own error-handling bootstrap, not
#    something introduced by this Docker packaging.
# 8) severe, high-impact bug found by actually completing "Add New User"
#    end to end in a browser (not by any static analysis — this is a
#    runtime type-marshalling failure with no trace in the source text):
#    core/server/xmlrpcserver.py's do_POST serializes a successful
#    handler's return value with `xmlrpclib.dumps(response,
#    methodresponse=1)`. Python 2's stdlib xmlrpclib has no marshaller
#    for `decimal.Decimal`, and PyGreSQL returns NUMERIC/DECIMAL Postgres
#    columns (credit, charges, any money field — pervasive in a billing
#    system) as Decimal. The instant a response contains one anywhere in
#    its structure, dumps() raises TypeError; this happens AFTER the
#    handler already ran successfully and OUTSIDE the try/except that
#    turns real handler errors into a proper XML-RPC fault (verified: a
#    HandlerException raised from inside a handler comes back as a
#    correct `FAULT: ...` string, but this TypeError does not), so it
#    falls into do_POST's outermost bare `except:` and returns a bare
#    HTTP 500 with an empty body — indistinguishable, from the PHP
#    client's side, from the "Can't connect to IBS Core" symptom
#    documented for the user_actions.py bug above. Confirmed via the
#    direct-XML-RPC-test technique (calling user.getUserInfo directly)
#    and by reading /var/log/IBSng/ibs_error.log — a log file the admin
#    panel's own debugging notes don't mention, but which is exactly
#    where logException(LOG_ERROR,...) writes
#    (core/ibs_exceptions.py's toLog): it had the full Python traceback
#    ending in "TypeError: cannot marshal <class 'decimal.Decimal'>
#    objects". Reliably reproduced by adding a single user with any
#    credit value (including 0) and viewing the resulting user info page
#    — i.e. this breaks the Add New User flow for essentially everyone.
#    Fixed the way IBSng's own PyGreSQL shim above is fixed: register a
#    marshaller for decimal.Decimal (convert to float, then reuse
#    xmlrpclib's existing dump_double) in core/server/xmlrpcserver.py,
#    the one module that owns response serialization, so it runs once
#    at daemon startup and applies to every response for the life of the
#    process.
RUN sed -i 's/self\.getLoadedUsersByUsername(normal_username)/self.getLoadedUsersByNormalUsername(normal_username)/' /usr/local/IBSng/core/user/user_actions.py \
    && sed -i 's/self\.getDictWrapperResult(result)/self.getDicWrapperResult(result)/' /usr/local/IBSng/core/db/ibs_db.py \
    && sed -i 's/self\.__getPortFromOid(/self.__getPortFromOID(/g' /usr/local/IBSng/core/ras/rases/portmaster.py \
    && sed -i '0,/^require_once(IBSINC."group.php");/s//require_once("..\/user\/user_info_funcs.php");\n&/' /usr/local/IBSng/interface/IBSng/admin/plugins/edit_funcs.php \
    && sed -i \
        -e '/^ini_set("display_errors",1);$/d' \
        -e 's/if(\$errno!=2048)/if($errno!=8192)/' \
        /usr/local/IBSng/interface/IBSng/inc/error.php \
    && printf '\n# --- IBSng compatibility shim: xmlrpclib (Python 2 stdlib) cannot marshal\n# decimal.Decimal, which PyGreSQL returns for Postgres NUMERIC/DECIMAL\n# columns (credit, charges, ...). Without this, any response containing\n# one crashes serialization with an uncaught TypeError, surfacing to the\n# PHP admin panel as a bare HTTP 500 with no fault string. ---\nimport decimal as _ibsng_decimal\ndef _ibsng_dump_decimal(self, value, write):\n    self.dump_double(float(value), write)\nxmlrpclib.Marshaller.dispatch[_ibsng_decimal.Decimal] = _ibsng_dump_decimal\n# --- end shim ---\n' >> /usr/local/IBSng/core/server/xmlrpcserver.py \
    && sed -i '1i #coding:utf-8' /usr/local/IBSng/core/lib/IPy.py \
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

# 9) "Online Users" admin page (admin/report/online_users.php) has no
#    pagination at all: core/report/report_handler.py's getOnlineUsers()
#    always returns every currently-online session, and the page renders
#    every one of them into a single HTML table unconditionally. This is
#    a genuine architectural gap, not a typo — ReportHelper (the same
#    helper class every OTHER paginated report in this admin panel uses)
#    is already instantiated on this exact page for order_by/desc, and
#    was already computing getFrom()/getTo() the whole time — they were
#    simply never read. REPRODUCED (not just inferred): provisioned real
#    users and drove real RADIUS Access-Accept + this-page-load traffic
#    against a running instance of this image. At 800 concurrent online
#    users (minimal per-session RADIUS attributes) the page still
#    rendered fine, ~34MB peak PHP memory against the stock 128M
#    memory_limit. At ~3200 it reliably hit:
#      PHP Fatal error: Allowed memory size of 134217728 bytes exhausted
#      (tried to allocate 18528395 bytes) in
#      interface/smarty/plugins/block.listTable.php on line 54
#    — i.e. Smarty's listTable block plugin buffers the entire table as
#    one string before returning it, so memory grows without bound as
#    online count grows, with no cap anywhere in the chain. Because
#    display_errors is (correctly, see above) Off, this fatal error
#    produces exactly the reported symptom: page returns 200 with a
#    truncated, near-empty body and no visible error — the real error
#    only shows up in php.ini's own error_log. (The core side is not the
#    bottleneck: building and returning the full XML-RPC response for
#    3200+ sessions took well under a second in testing.) A production
#    deployment hitting this around ~800 rather than ~3000+ is consistent
#    with real NAS hardware attaching more per-session RADIUS attributes
#    per online record than this minimal synthetic test did (each extra
#    attribute is more data duplicated into every row's in-memory dict
#    AND into the per-row hidden "details" popup in the same template) —
#    the exact per-row byte size isn't what matters here, since it's
#    fundamentally an unbounded-growth bug: whatever the real per-row
#    cost is, *some* online count will always eventually exhaust
#    memory_limit without a cap somewhere. Fixed at the actual source of
#    the unbounded growth rather than by raising memory_limit (which
#    would only move the threshold, not remove it): report_handler.py's
#    getOnlineUsers() now takes "from"/"to" (same convention as every
#    other paginated report method in core/, e.g. getConnections) and
#    slices the already-sorted result before returning it, so the
#    response size is bounded regardless of true online count; the PHP
#    caller now actually uses the from/to ReportHelper was already
#    computing, and the template shows total-count + the same
#    {reportPages} page-nav widget every other paginated report page in
#    this admin panel already uses. Defaults to 100 rows/page. Also
#    fixed, while wiring this up: {reportPages}'s own generated "page 2"
#    links never actually work anywhere in IBSng unless "rpp" already
#    happens to be in the request (ReportHelper only reads page/rpp when
#    BOTH are present, and nothing anywhere ever seeds "rpp" by default)
#    — a real, pre-existing bug affecting every other page that already
#    uses this same pagination convention, not something new. Worked
#    around locally (defaulting $_REQUEST["rpp"] once, up front, on this
#    page only) rather than touching the shared plugin, since fixing that
#    globally is a separate, riskier change outside this bug's scope.
#    See README.md for the full before/after numbers, verification at
#    3200+ concurrent online users, and the safe-up-to figure this leaves
#    the page at.
COPY files/patches/paginate_online_users.py files/patches/paginate_online_users_funcs.py /tmp/patches/
RUN python2.7 /tmp/patches/paginate_online_users.py \
    && python2.7 /tmp/patches/paginate_online_users_funcs.py \
    && sed -i 's/function GetOnlineUsers(\$normal_sort_by, \$normal_desc, \$voip_sort_by, \$voip_desc, \$conds)/function GetOnlineUsers($normal_sort_by, $normal_desc, $voip_sort_by, $voip_desc, $conds, $from, $to)/' /usr/local/IBSng/interface/IBSng/inc/report.php \
    && sed -i 's/^                                                      "conds"=>\$conds));$/                                                      "conds"=>$conds,\n                                                      "from"=>(int)$from,\n                                                      "to"=>(int)$to));/' /usr/local/IBSng/interface/IBSng/inc/report.php \
    && printf '\n<div align=center>\n    Total Internet Online Users: {$internet_onlines_total}\n    <br>\n    {reportPages total_results=$internet_onlines_total ignore_in_url="voip_order_by,voip_desc"}\n</div>\n' >> /usr/local/IBSng/interface/smarty/templates/admin/report/internet_onlines.tpl \
    && rm -rf /tmp/patches

# 10) the SourceForge release tarball ships interface/smarty/templates_c/
#    pre-populated with Smarty's own compiled-template cache from whenever
#    the upstream maintainers last rendered these pages themselves —
#    Smarty only recompiles a cached .tpl.php when its source .tpl is
#    newer than the compiled copy, so any of these stale entries whose
#    source .tpl this Dockerfile patches above (or whose PHP controller
#    the sed/patch steps above touch) keep silently serving pre-patch
#    output forever, with no error anywhere (Smarty's cache check is
#    silent by design). REPRODUCED against a real deployment: the Search
#    User page's "Attributes to Edit" checkboxes never showed their
#    correct default-checked set, and the Home page's Report menu was
#    missing the "Deposit Changes" link entirely — both confirmed to
#    correspond to a compiled templates_c/*.tpl.php that visibly lacked
#    content present in the actual current source .tpl. Fixed by clearing
#    every pre-baked compiled template after all patches above are
#    applied, so the very first request against a fresh container
#    recompiles from the final, patched source instead of whatever the
#    upstream tarball happened to ship. This costs a one-time recompile
#    per template on first access after container start — negligible,
#    and it also means a `docker restart` never has stale content to
#    worry about (Smarty writes back into this same, persistent-within-
#    the-image directory).
RUN find /usr/local/IBSng/interface/smarty/templates_c -mindepth 1 -delete

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
