//go:build linux

package service

import (
	"fmt"
	"os"
	"syscall"
)

// AcquireLock не даёт full, update и uninstall выполняться одновременно. Выход освобождает блокировку.
// Файл блокировки не удаляем: другой процесс может уже держать его открытым.
func AcquireLock() (*os.File, error) {
	f, err := os.OpenFile("/run/sys-ipfilter.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("another sys-ipfilter operation is running: %w", err)
	}
	return f, nil
}
