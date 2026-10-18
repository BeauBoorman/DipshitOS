//go:build !virelai

package fatimg

import "os"

// osSink is the host SeqSink used by tests and dev runs: a plain file.
type osSink struct {
	f   *os.File
	pos uint64
}

func NewSeqSink(path string) (SeqSink, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &osSink{f: f}, nil
}

func (s *osSink) Write(b []byte) (int, error) {
	n, err := s.f.Write(b)
	s.pos += uint64(n)
	return n, err
}

func (s *osSink) ZeroPad(to uint64) error {
	if err := s.f.Truncate(int64(to)); err != nil {
		return err
	}
	if _, err := s.f.Seek(int64(to), 0); err != nil {
		return err
	}
	s.pos = to
	return nil
}

func (s *osSink) Close() error {
	if err := s.f.Sync(); err != nil {
		s.f.Close()
		return err
	}
	return s.f.Close()
}
