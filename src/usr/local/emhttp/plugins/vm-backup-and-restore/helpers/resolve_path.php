<?php
declare(strict_types=1);
header('Content-Type: text/plain');

// Path is returned as-is — realpath() intentionally removed to prevent
// symlinks like /mnt/user being silently resolved to their physical target
// (e.g. /mnt/cache), which would corrupt saved settings and the UI display.
$path_str = $_POST['path'] ?? '';
echo $path_str;