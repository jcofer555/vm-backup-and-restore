<?php
header('Content-Type: application/json');

$restorePath = rtrim($_GET['restore_path'] ?? '', '/');

if ($restorePath === '' || !is_dir($restorePath) || strpos($restorePath, '/mnt') !== 0) {
    echo json_encode([]);
    exit;
}

$result = [];

foreach (scandir($restorePath) as $vmFolder) {

    if ($vmFolder === '.' || $vmFolder === '..' || $vmFolder === 'logs') {
        continue;
    }

    $vmPath = $restorePath . '/' . $vmFolder;
    if (!is_dir($vmPath)) continue;

    $groups = [];

    foreach (scandir($vmPath) as $file) {

        if (preg_match('/^(\d{8})_(\d{6})_.*\.(img|qcow2|xml|fd)$/i', $file, $m)) {

            $timestamp = $m[1] . '-' . $m[2];
            $ext = strtolower($m[3]);

            if (!isset($groups[$timestamp])) {
                $groups[$timestamp] = [
                    'img' => false,
                    'qcow2' => false,
                    'xml' => false,
                    'fd' => false
                ];
            }

            $groups[$timestamp][$ext] = true;
        }
    }

    foreach ($groups as $ts => $found) {

        $hasDisk = $found['img'] || $found['qcow2'];
        $hasXML  = $found['xml'];
        $hasNVRAM = $found['fd'];

        $missing = [];

        if (!$hasDisk)  $missing[] = 'vdisk';
        if (!$hasXML)   $missing[] = 'xml';
        if (!$hasNVRAM) $missing[] = 'nvram';

        if (!empty($missing)) {

            $dt = DateTime::createFromFormat("Ymd-His", $ts);
            $display = $dt ? $dt->format("Y-m-d H:i:s") : $ts;

            $result[] = [
                "vm" => $vmFolder,
                "backup" => $display,
                "missing" => $missing
            ];
        }
    }
}

echo json_encode($result);