<?php
// iftest web UI guard — localhost, or authenticated maxsim dev when behind the maxsim proxy.
// Override allowed IPs: IFTEST_WEB_ALLOW="127.0.0.1,::1,10.0.0.5"

$iftest_allow = array_map('trim', explode(',', getenv('IFTEST_WEB_ALLOW') ?: '127.0.0.1,::1'));

$iftest_proxied = isset($_SERVER['HTTP_X_MAXSIM_EDGE']);
$iftest_dev     = (($_SERVER['HTTP_X_MAXSIM_AUTH_DEV'] ?? '') === '1');

if ($iftest_proxied) {

    if (!$iftest_dev) {
        http_response_code(403);
        exit('403 — iftest web UI requires an authenticated dev session (login at /maxsim/auth)');
    }

} elseif (!in_array($_SERVER['REMOTE_ADDR'] ?? '', $iftest_allow, true)) {
    http_response_code(403);
    exit('403 — iftest web UI is localhost only (set IFTEST_WEB_ALLOW to override)');
}
