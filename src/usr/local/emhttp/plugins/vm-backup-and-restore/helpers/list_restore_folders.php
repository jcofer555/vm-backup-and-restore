<?php
header('Content-Type: application/json');

$restorePath = rtrim($_GET['restore_path'] ?? '', '/');

if ($restorePath === '' || !is_dir($restorePath) || strpos($restorePath, '/mnt') !== 0) {
    echo json_encode(['folders' => []]);
    exit;
}

$folders = array_filter(scandir($restorePath), function ($item) use ($restorePath) {
    if ($item === '.' || $item === '..' || $item === 'logs') {
        return false;
    }

    $full = $restorePath . '/' . $item;
    if (!is_dir($full)) {
        return false;
    }

    // Group files by timestamp
    $groups = [];

    foreach (scandir($full) as $file) {
        // Match: YYYYMMDD_HHMMSS_*.ext
        if (preg_match('/^(\d{8}_\d{6})_.*\.(img|xml|fd)$/i', $file, $m)) {
            $ts  = $m[1];      // timestamp
            $ext = strtolower($m[2]); // extension

            if (!isset($groups[$ts])) {
                $groups[$ts] = ['img' => false, 'xml' => false, 'fd' => false];
            }

            $groups[$ts][$ext] = true;
        }
    }

    // Folder is valid if ANY timestamp group has all 3 required files
    foreach ($groups as $ts => $found) {
        if ($found['img'] && $found['xml'] && $found['fd']) {
            return true;
        }
    }

    return false;
});

echo json_encode(['folders' => array_values($folders)]);
