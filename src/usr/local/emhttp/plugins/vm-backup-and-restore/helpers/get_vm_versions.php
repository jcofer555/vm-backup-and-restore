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
$versions = [];

/*
  Match files that begin with:
  YYYYMMDD_HHMMSS
*/
foreach ($files as $file) {

    if (preg_match('/^(\d{8})_(\d{6})/', $file, $m)) {

        $raw = $m[1] . '-' . $m[2]; // YYYYMMDD-HHMMSS
        $versions[$raw][] = $file;
    }
}

$out = [];

foreach ($versions as $raw => $filesForVersion) {

    $hasDisk  = false;
    $hasXML   = false;
    $hasNVRAM = false;

    foreach ($filesForVersion as $file) {

        $ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));

        if ($ext === 'img' || $ext === 'qcow2') {
            $hasDisk = true;
        }

        if ($ext === 'xml') {
            $hasXML = true;
        }

        if ($ext === 'fd') {
            $hasNVRAM = true;
        }
    }

    $missing = [];

    if (!$hasDisk)  $missing[] = 'vdisk';
    if (!$hasXML)   $missing[] = 'xml';
    if (!$hasNVRAM) $missing[] = 'nvram';

    $dt = DateTime::createFromFormat("Ymd-His", $raw);
    $display = $dt ? $dt->format("Y-m-d H:i:s") : $raw;

    $out[] = [
        "raw"       => $raw,
        "display"   => $display,
        "malformed" => count($missing) > 0,
        "missing"   => $missing
    ];
}

/* Sort newest first */
usort($out, function ($a, $b) {
    return strcmp($b['raw'], $a['raw']);
});

echo json_encode($out);