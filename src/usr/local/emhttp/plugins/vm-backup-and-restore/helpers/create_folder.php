<?php

declare(strict_types=1);
header('Content-Type: application/json');

// --- CSRF validation ---
$csrf_cookie_str = $_COOKIE['csrf_token'] ?? '';
$csrf_post_str   = $_POST['csrf_token']   ?? '';

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals($csrf_cookie_str, $csrf_post_str)) {
    echo json_encode(['ok' => false, 'error' => 'Invalid CSRF token']);
    exit;
}

// --- Validate input ---
$raw_path_str  = $_POST['path'] ?? '';
$folder_name_str = basename($_POST['name'] ?? '');

$parent_path_str = realpath($raw_path_str);

if ($parent_path_str === false || $folder_name_str === '' || !is_dir($parent_path_str)) {
    echo json_encode(['success' => false, 'error' => 'Invalid path']);
    exit;
}

$new_path_str = $parent_path_str . '/' . $folder_name_str;

if (file_exists($new_path_str)) {
    echo json_encode(['success' => false, 'error' => 'Already exists']);
    exit;
}

// --- Inherit parent permissions ---
$stat_arr  = stat($parent_path_str);
$uid_int   = (int)$stat_arr['uid'];
$gid_int   = (int)$stat_arr['gid'];
$mode_int  = (int)$stat_arr['mode'] & 0777;

mkdir($new_path_str, $mode_int, false);
chown($new_path_str, $uid_int);
chgrp($new_path_str, $gid_int);

echo json_encode(['success' => true]);
