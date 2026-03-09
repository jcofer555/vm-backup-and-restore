<?php
declare(strict_types=1);
header('Content-Type: application/json');

// --- CSRF validation ---
$csrf_header_str = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
$csrf_post_str   = $_POST['csrf_token']          ?? '';
$csrf_cookie_str = $_COOKIE['csrf_token']        ?? '';

if ($csrf_header_str === '' && $csrf_post_str === '') {
    http_response_code(403);
    echo json_encode(['status' => 'error', 'message' => 'Missing CSRF token']);
    exit;
}

if (!hash_equals($csrf_cookie_str, $csrf_header_str) && !hash_equals($csrf_cookie_str, $csrf_post_str)) {
    http_response_code(403);
    echo json_encode(['status' => 'error', 'message' => 'Invalid CSRF token']);
    exit;
}

// --- Log target map ---
const LOG_FILES = [
    'last' => '/tmp/vm-backup-and-restore/vm-backup-and-restore.log',
];

$log_str = $_POST['log'] ?? '';

if (!array_key_exists($log_str, LOG_FILES)) {
    echo json_encode(['status' => 'error', 'message' => 'Invalid log target']);
    exit;
}

$file_path_str = LOG_FILES[$log_str];

if (!file_exists($file_path_str)) {
    echo json_encode(['status' => 'error', 'message' => 'Log file not found']);
    exit;
}

file_put_contents($file_path_str, '');

echo json_encode([
    'ok'      => true,
    'message' => '✅ ' . ucfirst($log_str) . ' log cleared successfully.',
]);
