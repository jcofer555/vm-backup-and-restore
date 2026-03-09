<?php
declare(strict_types=1);
header('Content-Type: application/json');

// --- Constants ---
const LOCK_DIR      = '/tmp/vm-backup-and-restore';
const LOCK_FILE     = LOCK_DIR . '/lock.txt';
const RESTORE_SCRIPT = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/restore.sh';

// --- Utility ---
function json_error(string $message): void
{
    echo json_encode(['status' => 'error', 'message' => $message]);
    exit;
}

// --- Ensure lock directory ---
if (!is_dir(LOCK_DIR)) {
    mkdir(LOCK_DIR, 0777, true);
}

// --- Validate script ---
if (!is_file(RESTORE_SCRIPT) || !is_executable(RESTORE_SCRIPT)) {
    json_error('Restore script missing or not executable');
}

// --- Check for live process via existing lock ---
if (file_exists(LOCK_FILE)) {
    $contents_str = (string)file_get_contents(LOCK_FILE);
    preg_match('/PID=(\d+)/', $contents_str, $pid_matches);
    $existing_pid_int = isset($pid_matches[1]) ? (int)$pid_matches[1] : 0;
    if ($existing_pid_int > 0 && file_exists("/proc/$existing_pid_int")) {
        json_error('Backup or restore already running');
    }
    @unlink(LOCK_FILE);
}

// --- Write placeholder lock before launch ---
$placeholder_str = "PID=0\nMODE=restore\nSTART=" . time() . "\n";
if (file_put_contents(LOCK_FILE, $placeholder_str, LOCK_EX) === false) {
    json_error('Unable to write lock file');
}

// --- Launch restore script ---
$cmd_str = 'nohup /bin/bash ' . escapeshellarg(RESTORE_SCRIPT) . ' >/dev/null 2>&1 & echo $!';
$pid_str = trim((string)shell_exec($cmd_str));

if ($pid_str === '' || !is_numeric($pid_str)) {
    @unlink(LOCK_FILE);
    json_error('Failed to start restore');
}

// --- Update lock with real PID ---
$pid_int = (int)$pid_str;
file_put_contents(LOCK_FILE, "PID=$pid_int\nMODE=restore\nSTART=" . time() . "\n", LOCK_EX);

echo json_encode(['status' => 'ok', 'pid' => $pid_int]);
