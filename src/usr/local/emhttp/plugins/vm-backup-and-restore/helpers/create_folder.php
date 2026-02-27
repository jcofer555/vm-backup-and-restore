<?php
// ==============================
// CSRF VALIDATION
// ==============================
$cookie = $_COOKIE['csrf_token'] ?? '';
$posted = $_POST['csrf_token'] ?? '';

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals($cookie, $posted)) {
    echo json_encode(["ok" => false, "error" => "Invalid CSRF token"]);
    exit;
}

header('Content-Type: application/json');

$parent = realpath($_POST['path'] ?? '');
$name   = basename($_POST['name'] ?? '');

if (!$parent || !$name || !is_dir($parent)) {
  echo json_encode(['success' => false, 'error' => 'Invalid path']);
  exit;
}

$new = $parent . '/' . $name;

if (file_exists($new)) {
  echo json_encode(['success' => false, 'error' => 'Already exists']);
  exit;
}

$stat = stat($parent);
$uid  = $stat['uid'];
$gid  = $stat['gid'];
$mode = $stat['mode'] & 0777;

mkdir($new, $mode, false);
chown($new, $uid);
chgrp($new, $gid);

echo json_encode(['success' => true]);