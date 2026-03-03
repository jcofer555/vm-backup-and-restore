<?php
header('Content-Type: application/json');

$vm = $_GET['vm'] ?? '';
$restorePath = $_GET['restore_path'] ?? '';
$basePath = rtrim($restorePath, '/') . '/' . $vm;

if (!is_dir($basePath)) {
    echo json_encode([]);
    exit;
}

$files = scandir($basePath);
$timestamps = [];

// Extract timestamps from filenames: YYYYMMDD_HHMMSS
foreach ($files as $file) {
    if (preg_match('/^(\d{8})_(\d{6})/', $file, $m)) {
        $raw = $m[1] . '-' . $m[2]; // YYYYMMDD-HHMMSS
        $timestamps[$raw] = true;   // dedupe
    }
}

$unique = array_keys($timestamps);

// Sort newest → oldest
rsort($unique, SORT_STRING);

$out = [];

foreach ($unique as $raw) {
    $dt = DateTime::createFromFormat("Ymd-His", $raw);
    $display = $dt ? $dt->format("Y-m-d H:i:s") : $raw;

    $out[] = [
        "raw"     => $raw,
        "display" => $display
    ];
}

echo json_encode($out);
