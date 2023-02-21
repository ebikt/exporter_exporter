// Copyright 2016 Qubit Ltd.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	log "github.com/sirupsen/logrus"
)

var (
	fileStartsCount = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "expexp_command_starts_total",
			Help: "Counts of command starts",
		},
		[]string{"module"},
	)
	fileFailsCount = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "expexp_command_fails_total",
			Help: "Count of commands with non-zero exits",
		},
		[]string{"module"},
	)
)

func readFileWithDeadline(path string, t time.Time) ([]byte, time.Time, error) {
	f, err := os.Open(path)
	mtime := time.Time{}
	if err != nil {
		return nil, mtime, err
	}
	defer f.Close()
	f.SetDeadline(t)

	var size int
	if info, err := f.Stat(); err == nil {
		size64 := info.Size()
		if int64(int(size64)) == size64 {
			size = int(size64)
		}
		if info.Mode().IsRegular() {
			mtime = info.ModTime()
		}
	}
	size++ // one byte for final read at EOF

	// If a file claims a small size, read at least 512 bytes.
	// In particular, files in Linux's /proc claim size 0 but
	// then do not work right if read in small pieces,
	// so an initial read of 1 byte would not work correctly.
	if size < 512 {
		size = 512
	}

	data := make([]byte, 0, size)
	for {
		if time.Now().After(t) {
			return data, mtime, os.ErrDeadlineExceeded
		}
		if len(data) >= cap(data) {
			d := append(data[:cap(data)], 0)
			data = d[:len(data)]
		}
		n, err := f.Read(data[len(data):cap(data)])
		data = data[:len(data)+n]
		if err != nil {
			if err == io.EOF {
				err = nil
			}
			return data, mtime, err
		}
	}
}

var (
	mtimeName = "expexp_file_mtime"
	mtimeHelp = "Time of modification of parsed file (in miliseconds)"
	mtimeType = dto.MetricType_GAUGE
	mtimeLabelModule = "module"
	mtimeLabelPath   = "path"
)

func (c fileConfig) GatherWithContext(ctx context.Context, r *http.Request, path string) prometheus.GathererFunc {
	return func() ([]*dto.MetricFamily, error) {

		errc := make(chan error, 1)
		datc := make(chan []byte, 1)
		timec := make(chan time.Time, 1)
		go func() {
			deadline, ok := ctx.Deadline()
			if ! ok { deadline = time.Now().Add(time.Minute * 5) }
			dat, mtime, err := readFileWithDeadline(path, deadline)
			errc <- err
			if err == nil {
			    datc <- dat
			    timec <- mtime
			}
			close(errc)
			close(datc)
			close(timec)
		}()

		err := <- errc
		if err != nil {
			log.Warnf("File module %v failed to read file %v, %+v", c.mcfg.name, path, err)
			fileFailsCount.WithLabelValues(c.mcfg.name).Inc()
			if err == context.DeadlineExceeded || err == os.ErrDeadlineExceeded {
				proxyTimeoutCount.WithLabelValues(c.mcfg.name).Inc()
			}
			return nil, err
		}
		dat := <- datc
		mtime := <- timec
		var prsr expfmt.TextParser

		var mtimeBuf *int64 = nil
		if ! mtime.IsZero() {
			mtimeBuf = new(int64)
			*mtimeBuf = mtime.UnixMilli()
		}

		var result []*dto.MetricFamily
		mfs, err := prsr.TextToMetricFamilies(bytes.NewReader(dat))
		if err != nil {
			proxyMalformedCount.WithLabelValues(c.mcfg.name).Inc()
			return nil, err
		}
		for _, mf := range mfs {
			if c.UseMtime && mtimeBuf != nil {
				for _, m := range mf.GetMetric() {
					m.TimestampMs = mtimeBuf
				}
			}
			result = append(result, mf)
		}
		if !mtime.IsZero() {
			v := float64(mtime.UnixMilli())
			g := dto.Gauge { Value: &v, }
			l := make([]*dto.LabelPair, 2)
			l[0] = &dto.LabelPair{
				Name:&mtimeLabelModule,
				Value:&c.mcfg.name,
			}
			l[1] = &dto.LabelPair{
				Name:&mtimeLabelPath,
				Value:&path,
			}
			m := dto.Metric {
				Label: l,
				Gauge: &g,
			}
			mf := dto.MetricFamily{
				Name: &mtimeName,
				Help: &mtimeHelp,
				Type: &mtimeType,
			}
			mf.Metric = append(mf.Metric, &m)
			result = append(result, &mf)
		}
		return result, nil
	}
}

var cleanSlashes = regexp.MustCompile("(^|/)/+")

func (c fileConfig) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	qvs := r.URL.Query()
	path := cleanSlashes.ReplaceAllString(qvs.Get("path"),"$1")

	if c.AllowRe == nil {
		if path != "" {
			_, _ = w.Write([]byte("Invalid path argument"))
			return
		}
	} else {
		if c.AllowRe.MatchString(path) {
			_, _ = w.Write([]byte("Invalid path argument"))
			return
		}
	}
	if path != "" {
		path = "/" + path
		if strings.Contains(path, "/.") {
			_, _ = w.Write([]byte("Dot files are not allowed"))
			return
		}
	}

	ctx := r.Context()
	g := c.GatherWithContext(ctx, r, c.Path + path)
	promhttp.HandlerFor(g, promhttp.HandlerOpts{}).ServeHTTP(w, r)
}
