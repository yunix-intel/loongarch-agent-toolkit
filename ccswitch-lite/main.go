// ccswitch-lite: a small, dependency-free provider switcher for
// Claude Desktop (3P gateway), Claude Code and Codex CLI.
//
// It is a LoongArch-native replacement for the parts of farion1231/cc-switch
// that matter on this machine. Everything is stdlib-only.
package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	version      = "1.0.0"
	profileID    = "00000000-0000-4000-8000-000000157210"
	profileName  = "CC Switch"
	defaultAddr  = "127.0.0.1:18081"
	codexSlugPfx = "ccswitch-"
)

// ---------------------------------------------------------------------------
// data model

type Models struct {
	Sonnet string `json:"sonnet,omitempty"`
	Opus   string `json:"opus,omitempty"`
	Haiku  string `json:"haiku,omitempty"`
	Fable  string `json:"fable,omitempty"`
}

type Provider struct {
	Name         string            `json:"name"`
	BaseURL      string            `json:"baseUrl"`
	APIKey       string            `json:"apiKey"`
	APIFormat    string            `json:"apiFormat"` // anthropic | openai
	DefaultModel string            `json:"defaultModel,omitempty"`
	Models       Models            `json:"models,omitempty"`
	ExtraHeaders map[string]string `json:"extraHeaders,omitempty"`
}

type Applied struct {
	Provider     string `json:"provider,omitempty"`
	CodexSlug    string `json:"codexSlug,omitempty"`
	WroteAuthKey bool   `json:"wroteAuthKey,omitempty"`
	At           string `json:"at,omitempty"`
}

type Store struct {
	Current   string     `json:"current"`
	Providers []Provider `json:"providers"`
	Applied   Applied    `json:"applied,omitempty"`
}

// ---------------------------------------------------------------------------
// paths

type Paths struct {
	Home            string
	ConfigHome      string
	Store           string
	LogFile         string
	DesktopConfig   string
	Desktop3PConfig string
	ProfileFile     string
	MetaFile        string
	ClaudeSettings  string
	CodexDir        string
	CodexConfig     string
	CodexAuth       string
}

func homeDir() (string, error) {
	if h := os.Getenv("HOME"); h != "" {
		return h, nil
	}
	return os.UserHomeDir()
}

func resolvePaths() (*Paths, error) {
	home, err := homeDir()
	if err != nil {
		return nil, err
	}
	cfg := os.Getenv("XDG_CONFIG_HOME")
	if cfg == "" {
		cfg = filepath.Join(home, ".config")
	}
	claudeDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if claudeDir == "" {
		claudeDir = filepath.Join(home, ".claude")
	}
	codexDir := os.Getenv("CODEX_HOME")
	if codexDir == "" {
		codexDir = filepath.Join(home, ".codex")
	}
	lib := filepath.Join(cfg, "Claude-3p", "configLibrary")
	return &Paths{
		Home:            home,
		ConfigHome:      cfg,
		Store:           filepath.Join(cfg, "ccswitch-lite", "providers.json"),
		LogFile:         filepath.Join(cfg, "ccswitch-lite", "logs", "ccswitch.log"),
		DesktopConfig:   filepath.Join(cfg, "Claude", "claude_desktop_config.json"),
		Desktop3PConfig: filepath.Join(cfg, "Claude-3p", "claude_desktop_config.json"),
		ProfileFile:     filepath.Join(lib, profileID+".json"),
		MetaFile:        filepath.Join(lib, "_meta.json"),
		ClaudeSettings:  filepath.Join(claudeDir, "settings.json"),
		CodexDir:        codexDir,
		CodexConfig:     filepath.Join(codexDir, "config.toml"),
		CodexAuth:       filepath.Join(codexDir, "auth.json"),
	}, nil
}

// ---------------------------------------------------------------------------
// store

var storeMu sync.Mutex

func loadStore(p *Paths) (*Store, error) {
	data, err := os.ReadFile(p.Store)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &Store{Providers: []Provider{}}, nil
		}
		return nil, err
	}
	var s Store
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&s); err != nil {
		return nil, fmt.Errorf("providers.json 解析失败: %w", err)
	}
	if s.Providers == nil {
		s.Providers = []Provider{}
	}
	return &s, nil
}

func saveStore(p *Paths, s *Store) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if _, err := backupFile(p.Store); err != nil {
		return err
	}
	return atomicWrite(p.Store, data, 0600)
}

func (s *Store) find(name string) *Provider {
	for i := range s.Providers {
		if s.Providers[i].Name == name {
			return &s.Providers[i]
		}
	}
	return nil
}

func (s *Store) upsert(pr Provider) {
	for i := range s.Providers {
		if s.Providers[i].Name == pr.Name {
			s.Providers[i] = pr
			return
		}
	}
	s.Providers = append(s.Providers, pr)
}

func (s *Store) remove(name string) bool {
	for i := range s.Providers {
		if s.Providers[i].Name == name {
			s.Providers = append(s.Providers[:i], s.Providers[i+1:]...)
			if s.Current == name {
				s.Current = ""
			}
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// file helpers

func backupFile(path string) (string, error) {
	st, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}
	if !st.Mode().IsRegular() {
		return "", fmt.Errorf("%s 不是普通文件", path)
	}
	dst := path + ".bak." + time.Now().Format("20060102-150405.000000000")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(dst, data, st.Mode().Perm()); err != nil {
		return "", err
	}
	return dst, nil
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// writeValidated backs up, writes atomically, then re-reads and validates.
// If validation fails the previous file is restored from the backup.
func writeValidated(path string, data []byte, mode os.FileMode, validate func([]byte) error) (string, error) {
	if validate != nil {
		if err := validate(data); err != nil {
			return "", fmt.Errorf("内部校验失败（未写入 %s）: %w", path, err)
		}
	}
	bak, err := backupFile(path)
	if err != nil {
		return "", err
	}
	if err := atomicWrite(path, data, mode); err != nil {
		return bak, err
	}
	if validate != nil {
		got, err := os.ReadFile(path)
		if err != nil || validate(got) != nil {
			if bak != "" {
				restoreErr := restoreFile(bak, path)
				if restoreErr != nil {
					return bak, fmt.Errorf("写入 %s 后校验失败且回滚失败: %v (校验错误: %v)", path, restoreErr, err)
				}
				return bak, fmt.Errorf("写入 %s 后校验失败，已从备份恢复: %v", path, err)
			}
			os.Remove(path)
			return bak, fmt.Errorf("写入 %s 后校验失败，已删除新文件: %v", path, err)
		}
	}
	return bak, nil
}

func restoreFile(bak, path string) error {
	data, err := os.ReadFile(bak)
	if err != nil {
		return err
	}
	st, err := os.Stat(bak)
	if err != nil {
		return err
	}
	return atomicWrite(path, data, st.Mode().Perm())
}

// ---------------------------------------------------------------------------
// JSON helpers

func decodeJSON(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return nil, errors.New("JSON 尾部存在多余内容")
	}
	return v, nil
}

func readJSONObject(path string) (map[string]any, []byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return map[string]any{}, nil, nil
		}
		return nil, nil, err
	}
	v, err := decodeJSON(data)
	if err != nil {
		return nil, data, fmt.Errorf("%s 不是合法 JSON: %w", path, err)
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, data, fmt.Errorf("%s 顶层不是 JSON 对象", path)
	}
	return obj, data, nil
}

func marshalJSON(v any) []byte {
	data, _ := json.MarshalIndent(v, "", "  ")
	return append(data, '\n')
}

func validateJSONBytes(data []byte) error {
	_, err := decodeJSON(data)
	return err
}

func mergeJSON(path string, set func(map[string]any) error) (string, error) {
	obj, _, err := readJSONObject(path)
	if err != nil {
		return "", err
	}
	if err := set(obj); err != nil {
		return "", err
	}
	return writeValidated(path, marshalJSON(obj), 0600, validateJSONBytes)
}

// ---------------------------------------------------------------------------
// TOML helpers (textual merge; preserves everything we do not own)

var headerRe = regexp.MustCompile(`^\s*\[\[?([^\]]+)\]\]?\s*(#.*)?$`)

func splitDottedKey(s string) []string {
	var parts []string
	var cur strings.Builder
	var quote rune
	for _, r := range s {
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
			} else {
				cur.WriteRune(r)
			}
		case r == '"' || r == '\'':
			quote = r
		case r == '.':
			parts = append(parts, strings.TrimSpace(cur.String()))
			cur.Reset()
		default:
			cur.WriteRune(r)
		}
	}
	parts = append(parts, strings.TrimSpace(cur.String()))
	return parts
}

// checkTOML is deliberately tolerant: it verifies bracket/quote balance and
// duplicate table headers, but does not try to be a full TOML parser.
func checkTOML(data []byte) error {
	s := string(data)
	var (
		inBasic, inLiteral       bool
		inMultiBasic, inMultiLit bool
		depth                    int
		line                     int
		lineClean                = true
		headers                  = map[string]bool{}
	)
	rs := []rune(s)
	atLineStart := true
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		if r == '\n' {
			line++
			atLineStart = true
			lineClean = depth == 0 && !inBasic && !inLiteral && !inMultiBasic && !inMultiLit
			continue
		}
		if inMultiBasic {
			if r == '\\' && i+1 < len(rs) {
				i++
				continue
			}
			if r == '"' && i+2 < len(rs) && rs[i+1] == '"' && rs[i+2] == '"' {
				inMultiBasic = false
				i += 2
			}
			continue
		}
		if inMultiLit {
			if r == '\'' && i+2 < len(rs) && rs[i+1] == '\'' && rs[i+2] == '\'' {
				inMultiLit = false
				i += 2
			}
			continue
		}
		if inBasic {
			if r == '\\' && i+1 < len(rs) {
				i++
				continue
			}
			if r == '"' {
				inBasic = false
			}
			continue
		}
		if inLiteral {
			if r == '\'' {
				inLiteral = false
			}
			continue
		}
		if r == '#' {
			for i+1 < len(rs) && rs[i+1] != '\n' {
				i++
			}
			continue
		}
		if r == '"' {
			if i+2 < len(rs) && rs[i+1] == '"' && rs[i+2] == '"' {
				inMultiBasic = true
				i += 2
			} else {
				inBasic = true
			}
			atLineStart = false
			continue
		}
		if r == '\'' {
			if i+2 < len(rs) && rs[i+1] == '\'' && rs[i+2] == '\'' {
				inMultiLit = true
				i += 2
			} else {
				inLiteral = true
			}
			atLineStart = false
			continue
		}
		if r == '[' {
			if atLineStart && depth == 0 && lineClean {
				// table header; support both [table] and [[array-of-tables]]
				j := i + 1
				arrayTable := j < len(rs) && rs[j] == '['
				if arrayTable {
					j++
				}
				start := j
				for j < len(rs) && rs[j] != ']' && rs[j] != '\n' {
					j++
				}
				if j >= len(rs) || rs[j] != ']' {
					return fmt.Errorf("第 %d 行表头未闭合", line+1)
				}
				name := strings.TrimSpace(string(rs[start:j]))
				if arrayTable {
					if j+1 >= len(rs) || rs[j+1] != ']' {
						return fmt.Errorf("第 %d 行数组表头未闭合", line+1)
					}
					j++
				}
				norm := strings.Join(splitDottedKey(name), ".")
				if !arrayTable {
					if headers[norm] {
						return fmt.Errorf("重复的表头 [%s]", name)
					}
					headers[norm] = true
				}
				i = j
				continue
			}
			depth++
		} else if r == ']' {
			if depth > 0 {
				depth--
			} else if lineClean && atLineStart {
				return fmt.Errorf("第 %d 行存在多余的 ']'", line+1)
			}
		}
		if r != ' ' && r != '\t' {
			atLineStart = false
		}
	}
	if inBasic || inLiteral || inMultiBasic || inMultiLit {
		return errors.New("字符串未闭合")
	}
	if depth != 0 {
		return errors.New("方括号未配平")
	}
	return nil
}

func tomlQuote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 || r == 0x7f {
				b.WriteString(fmt.Sprintf(`\u%04X`, r))
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func codexSlug(name string) string {
	var b strings.Builder
	lastDash := false
	for _, r := range strings.ToLower(name) {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' || r == '-'
		if ok {
			b.WriteRune(r)
			lastDash = false
		} else if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	slug := strings.Trim(b.String(), "-")
	if slug == "" {
		slug = "provider"
	}
	return codexSlugPfx + slug
}

// mergeCodexConfig removes our top-level model_provider and the
// [model_providers.<slug>] tables, then appends a fresh block.
func mergeCodexConfig(old, slug, prName, baseURL string, headers map[string]string) string {
	lines := strings.Split(old, "\n")
	out := make([]string, 0, len(lines)+12)
	inTable := false
	skip := false
	for _, raw := range lines {
		line := strings.TrimSuffix(raw, "\r")
		trim := strings.TrimSpace(line)
		if m := headerRe.FindStringSubmatch(trim); m != nil {
			parts := splitDottedKey(strings.TrimSpace(m[1]))
			if len(parts) >= 2 && parts[0] == "model_providers" && strings.HasPrefix(parts[1], codexSlugPfx) {
				skip = true
				inTable = true
				continue
			}
			skip = false
			inTable = true
			out = append(out, line)
			continue
		}
		if skip {
			continue
		}
		if !inTable {
			if eq := strings.Index(trim, "="); eq > 0 {
				key := strings.TrimSpace(trim[:eq])
				if key == "model_provider" {
					continue
				}
			}
		}
		out = append(out, line)
	}
	// trim leading and trailing blank lines
	for len(out) > 0 && strings.TrimSpace(out[0]) == "" {
		out = out[1:]
	}
	for len(out) > 0 && strings.TrimSpace(out[len(out)-1]) == "" {
		out = out[:len(out)-1]
	}
	// model_provider is a top-level key: it must be emitted before the first
	// table header, otherwise TOML attaches it to the last surviving table.
	var b strings.Builder
	b.WriteString("model_provider = " + tomlQuote(slug) + "\n")
	if len(out) > 0 {
		b.WriteString("\n")
		b.WriteString(strings.Join(out, "\n"))
		b.WriteString("\n")
	}
	b.WriteString("\n[model_providers." + slug + "]\n")
	b.WriteString("name = " + tomlQuote(prName) + "\n")
	b.WriteString("base_url = " + tomlQuote(baseURL) + "\n")
	b.WriteString("env_key = \"OPENAI_API_KEY\"\n")
	b.WriteString("wire_api = \"responses\"\n")
	if len(headers) > 0 {
		keys := make([]string, 0, len(headers))
		for k := range headers {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		b.WriteString("\n[model_providers." + slug + ".http_headers]\n")
		for _, k := range keys {
			b.WriteString(tomlQuote(k) + " = " + tomlQuote(headers[k]) + "\n")
		}
	}
	return b.String()
}

// removeCodexConfig removes our provider table and model_provider, preserving
// everything else. If model_provider points elsewhere it is left untouched.
func removeCodexConfig(old, slug string) string {
	lines := strings.Split(old, "\n")
	out := make([]string, 0, len(lines))
	inTable := false
	skip := false
	for _, raw := range lines {
		line := strings.TrimSuffix(raw, "\r")
		trim := strings.TrimSpace(line)
		if m := headerRe.FindStringSubmatch(trim); m != nil {
			parts := splitDottedKey(strings.TrimSpace(m[1]))
			if len(parts) >= 2 && parts[0] == "model_providers" && strings.HasPrefix(parts[1], codexSlugPfx) {
				skip = true
				inTable = true
				continue
			}
			skip = false
			inTable = true
			out = append(out, line)
			continue
		}
		if skip {
			continue
		}
		if !inTable && strings.Contains(trim, "=") {
			key := strings.TrimSpace(strings.SplitN(trim, "=", 2)[0])
			val := strings.TrimSpace(strings.SplitN(trim, "=", 2)[1])
			if i := strings.Index(val, "#"); i >= 0 {
				val = strings.TrimSpace(val[:i])
			}
			if key == "model_provider" && strings.HasPrefix(strings.Trim(val, `"'`), codexSlugPfx) {
				continue
			}
		}
		out = append(out, line)
	}
	for len(out) > 0 && strings.TrimSpace(out[len(out)-1]) == "" {
		out = out[:len(out)-1]
	}
	if len(out) == 0 {
		return ""
	}
	return strings.Join(out, "\n") + "\n"
}

func codexProviderSlug(data []byte) string {
	inTable := false
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if strings.HasPrefix(line, "[") {
			inTable = true
			continue
		}
		if inTable {
			continue
		}
		eq := strings.Index(line, "=")
		if eq < 0 {
			continue
		}
		if strings.TrimSpace(line[:eq]) != "model_provider" {
			continue
		}
		v := strings.TrimSpace(line[eq+1:])
		if i := strings.Index(v, "#"); i >= 0 {
			v = strings.TrimSpace(v[:i])
		}
		v = strings.Trim(v, `"'`)
		return v
	}
	return ""
}

// ---------------------------------------------------------------------------
// apply / restore

type report struct {
	lines []string
}

func (r *report) add(format string, a ...any) {
	r.lines = append(r.lines, fmt.Sprintf(format, a...))
}

func maskKey(k string) string {
	if k == "" {
		return "(未设置)"
	}
	if len(k) <= 8 {
		return "********"
	}
	return k[:4] + "…" + k[len(k)-4:]
}

func normalizeProvider(p *Provider) error {
	p.Name = strings.TrimSpace(p.Name)
	p.BaseURL = strings.TrimSpace(p.BaseURL)
	p.APIKey = strings.TrimSpace(p.APIKey)
	p.APIFormat = strings.ToLower(strings.TrimSpace(p.APIFormat))
	if p.APIFormat == "" {
		p.APIFormat = "anthropic"
	}
	if p.Name == "" {
		return errors.New("name 不能为空")
	}
	if strings.ContainsAny(p.Name, "\r\n\t") {
		return errors.New("name 不能包含控制字符")
	}
	if p.BaseURL == "" {
		return errors.New("baseUrl 不能为空")
	}
	u, err := url.Parse(p.BaseURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("baseUrl 必须是 http(s) URL: %q", p.BaseURL)
	}
	if p.APIFormat != "anthropic" && p.APIFormat != "openai" {
		return fmt.Errorf("apiFormat 只能是 anthropic 或 openai: %q", p.APIFormat)
	}
	for k, v := range p.ExtraHeaders {
		if strings.TrimSpace(k) == "" || strings.ContainsAny(k, "\r\n:") {
			return fmt.Errorf("非法的 header 名称: %q", k)
		}
		if strings.ContainsAny(v, "\r\n") {
			return fmt.Errorf("header %q 的值包含换行", k)
		}
	}
	return nil
}

func inferenceModels(m Models) []any {
	type roleModel struct{ role, id string }
	roles := []roleModel{
		{"sonnet", m.Sonnet},
		{"opus", m.Opus},
		{"haiku", m.Haiku},
		{"fable", m.Fable},
	}
	seen := map[string]bool{}
	out := make([]any, 0, 4)
	for _, rm := range roles {
		id := strings.TrimSpace(rm.id)
		if id == "" {
			continue
		}
		supports1m := false
		lower := strings.ToLower(id)
		if strings.HasSuffix(lower, "[1m]") {
			id = strings.TrimSpace(id[:len(id)-4])
			supports1m = true
		}
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		item := map[string]any{"name": id}
		if supports1m {
			item["supports1m"] = true
			item["prefer1m"] = true
		}
		out = append(out, item)
	}
	return out
}

// preflight validates every existing file we are about to touch, so a bad
// file aborts the whole operation before anything is written.
func preflight(p *Paths) error {
	for _, path := range []string{
		p.DesktopConfig, p.Desktop3PConfig, p.ProfileFile, p.MetaFile, p.ClaudeSettings,
	} {
		if _, err := os.Stat(path); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return err
		}
		if _, _, err := readJSONObject(path); err != nil {
			return fmt.Errorf("预检失败，未写入任何文件: %w", err)
		}
	}
	if data, err := os.ReadFile(p.CodexConfig); err == nil {
		if err := checkTOML(data); err != nil {
			return fmt.Errorf("预检失败，未写入任何文件: %s: %w", p.CodexConfig, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func applyProvider(p *Paths, pr *Provider, st *Store) (*report, error) {
	r := &report{}
	if err := preflight(p); err != nil {
		return r, err
	}
	if pr.APIFormat == "openai" {
		r.add("提示: provider 为 openai 格式，Claude Desktop / Claude Code 需要 Anthropic 兼容端点，配置已照写。")
	}

	// --- Claude Desktop config (XDG ~/.config)
	for _, path := range []string{p.DesktopConfig, p.Desktop3PConfig} {
		bak, err := mergeJSON(path, func(obj map[string]any) error {
			obj["deploymentMode"] = "3p"
			return nil
		})
		if err != nil {
			return r, err
		}
		r.add("claude-desktop  %s  deploymentMode=3p%s", path, bakNote(bak))
	}

	// --- configLibrary profile
	profile := map[string]any{
		"coworkEgressAllowedHosts":     []any{"*"},
		"disableDeploymentModeChooser": true,
		"inferenceGatewayApiKey":       pr.APIKey,
		"inferenceGatewayAuthScheme":   "bearer",
		"inferenceGatewayBaseUrl":      pr.BaseURL,
		"inferenceProvider":            "gateway",
	}
	if models := inferenceModels(pr.Models); len(models) > 0 {
		profile["inferenceModels"] = models
	}
	bak, err := writeValidated(p.ProfileFile, marshalJSON(profile), 0600, validateJSONBytes)
	if err != nil {
		return r, err
	}
	r.add("claude-desktop  %s%s", p.ProfileFile, bakNote(bak))

	// --- configLibrary/_meta.json
	bak, err = mergeJSON(p.MetaFile, func(obj map[string]any) error {
		entries, _ := obj["entries"].([]any)
		found := false
		for i, e := range entries {
			if m, ok := e.(map[string]any); ok {
				if id, _ := m["id"].(string); id == profileID {
					m["name"] = profileName
					entries[i] = m
					found = true
				}
			}
		}
		if !found {
			entries = append(entries, map[string]any{"id": profileID, "name": profileName})
		}
		obj["entries"] = entries
		obj["appliedId"] = profileID
		return nil
	})
	if err != nil {
		return r, err
	}
	r.add("claude-desktop  %s  appliedId=%s%s", p.MetaFile, profileID, bakNote(bak))

	// --- Claude Code settings
	owned := []string{
		"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
		"ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
		"ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
	}
	desired := map[string]string{
		"ANTHROPIC_BASE_URL":   pr.BaseURL,
		"ANTHROPIC_AUTH_TOKEN": pr.APIKey,
	}
	if pr.DefaultModel != "" {
		desired["ANTHROPIC_MODEL"] = pr.DefaultModel
	}
	if pr.Models.Sonnet != "" {
		desired["ANTHROPIC_DEFAULT_SONNET_MODEL"] = pr.Models.Sonnet
	}
	if pr.Models.Opus != "" {
		desired["ANTHROPIC_DEFAULT_OPUS_MODEL"] = pr.Models.Opus
	}
	if pr.Models.Haiku != "" {
		desired["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = pr.Models.Haiku
	}
	if pr.Models.Fable != "" {
		desired["ANTHROPIC_DEFAULT_FABLE_MODEL"] = pr.Models.Fable
	}
	bak, err = mergeJSON(p.ClaudeSettings, func(obj map[string]any) error {
		env, _ := obj["env"].(map[string]any)
		if env == nil {
			env = map[string]any{}
		}
		for _, k := range owned {
			delete(env, k)
		}
		for k, v := range desired {
			env[k] = v
		}
		obj["env"] = env
		return nil
	})
	if err != nil {
		return r, err
	}
	r.add("claude-code     %s  env 已写入 (%s)%s", p.ClaudeSettings, maskKey(pr.APIKey), bakNote(bak))

	// --- Codex config.toml
	slug := codexSlug(pr.Name)
	old, err := os.ReadFile(p.CodexConfig)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return r, err
	}
	newToml := mergeCodexConfig(string(old), slug, pr.Name, pr.BaseURL, pr.ExtraHeaders)
	if err := checkTOML([]byte(newToml)); err != nil {
		return r, fmt.Errorf("生成的 Codex TOML 未通过校验: %w", err)
	}
	bak, err = writeValidated(p.CodexConfig, []byte(newToml), 0600, func(b []byte) error {
		if err := checkTOML(b); err != nil {
			return err
		}
		if codexProviderSlug(b) != slug {
			return errors.New("model_provider 未指向本工具")
		}
		if !bytes.Contains(b, []byte("[model_providers."+slug+"]")) {
			return errors.New("缺少 model_providers 表")
		}
		return nil
	})
	if err != nil {
		return r, err
	}
	r.add("codex           %s  model_provider=%s%s", p.CodexConfig, slug, bakNote(bak))

	// --- Codex auth.json (best effort, never overwrite a user's own key)
	wroteAuth := false
	if pr.APIKey != "" {
		authObj, _, aerr := readJSONObject(p.CodexAuth)
		if aerr != nil {
			r.add("codex           auth.json 不是合法 JSON，已跳过（未修改）: %v", aerr)
		} else {
			existing, has := authObj["OPENAI_API_KEY"]
			existingStr, _ := existing.(string)
			// We only own the key if a previous apply wrote it and it still
			// matches the provider we applied then.
			owned := false
			if st.Applied.WroteAuthKey && existingStr != "" {
				if prev := st.find(st.Applied.Provider); prev != nil && prev.APIKey == existingStr {
					owned = true
				}
			}
			switch {
			case has && strings.TrimSpace(existingStr) != "" && !owned:
				r.add("codex           auth.json 已有 OPENAI_API_KEY，保留未覆盖")
			case has && existingStr == pr.APIKey:
				wroteAuth = true
				r.add("codex           auth.json 的 OPENAI_API_KEY 由本工具写入，保持不变")
			default:
				authObj["OPENAI_API_KEY"] = pr.APIKey
				abak, aerr := writeValidated(p.CodexAuth, marshalJSON(authObj), 0600, validateJSONBytes)
				if aerr != nil {
					return r, aerr
				}
				wroteAuth = true
				r.add("codex           %s  已写入 OPENAI_API_KEY%s", p.CodexAuth, bakNote(abak))
			}
		}
	}

	st.Applied = Applied{Provider: pr.Name, CodexSlug: slug, WroteAuthKey: wroteAuth, At: time.Now().Format(time.RFC3339)}
	return r, nil
}

func bakNote(bak string) string {
	if bak == "" {
		return ""
	}
	return "  (备份: " + bak + ")"
}

func restoreAll(p *Paths, st *Store) (*report, error) {
	r := &report{}
	if err := preflight(p); err != nil {
		return r, err
	}
	for _, path := range []string{p.DesktopConfig, p.Desktop3PConfig} {
		if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
			r.add("claude-desktop  %s  不存在，跳过", path)
			continue
		}
		bak, err := mergeJSON(path, func(obj map[string]any) error {
			obj["deploymentMode"] = "1p"
			return nil
		})
		if err != nil {
			return r, err
		}
		r.add("claude-desktop  %s  deploymentMode=1p%s", path, bakNote(bak))
	}

	// _meta.json: drop our entry, pick the first remaining entry as appliedId.
	if _, err := os.Stat(p.MetaFile); errors.Is(err, os.ErrNotExist) {
		r.add("claude-desktop  %s  不存在，跳过", p.MetaFile)
	} else {
		bak, err := mergeJSON(p.MetaFile, func(obj map[string]any) error {
			entries, _ := obj["entries"].([]any)
			kept := make([]any, 0, len(entries))
			nextID := ""
			for _, e := range entries {
				m, ok := e.(map[string]any)
				if ok {
					if id, _ := m["id"].(string); id == profileID {
						continue
					}
					if nextID == "" {
						if id, _ := m["id"].(string); id != "" {
							nextID = id
						}
					}
				}
				kept = append(kept, e)
			}
			obj["entries"] = kept
			if id, _ := obj["appliedId"].(string); id == profileID {
				if nextID != "" {
					obj["appliedId"] = nextID
				} else {
					delete(obj, "appliedId")
				}
			}
			return nil
		})
		if err != nil {
			return r, err
		}
		r.add("claude-desktop  %s  已移除 profile 条目%s", p.MetaFile, bakNote(bak))
	}

	// Claude Code: remove the keys this tool owns.
	owned := []string{
		"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
		"ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
		"ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
	}
	if _, err := os.Stat(p.ClaudeSettings); errors.Is(err, os.ErrNotExist) {
		r.add("claude-code     %s  不存在，跳过", p.ClaudeSettings)
	} else {
		bak, err := mergeJSON(p.ClaudeSettings, func(obj map[string]any) error {
			env, _ := obj["env"].(map[string]any)
			if env != nil {
				for _, k := range owned {
					delete(env, k)
				}
				if len(env) == 0 {
					delete(obj, "env")
				}
			}
			return nil
		})
		if err != nil {
			return r, err
		}
		r.add("claude-code     %s  已移除本工具写入的 env%s", p.ClaudeSettings, bakNote(bak))
	}

	// Codex: remove our provider table.
	if _, err := os.Stat(p.CodexConfig); errors.Is(err, os.ErrNotExist) {
		r.add("codex           %s  不存在，跳过", p.CodexConfig)
	} else {
		old, err := os.ReadFile(p.CodexConfig)
		if err != nil {
			return r, err
		}
		slug := st.Applied.CodexSlug
		if slug == "" {
			if cur := codexProviderSlug(old); strings.HasPrefix(cur, codexSlugPfx) {
				slug = cur
			}
		}
		if slug == "" {
			r.add("codex           %s  未发现本工具的 provider 表，跳过", p.CodexConfig)
		} else {
			newToml := removeCodexConfig(string(old), slug)
			bak, err := writeValidated(p.CodexConfig, []byte(newToml), 0600, func(b []byte) error {
				return checkTOML(b)
			})
			if err != nil {
				return r, err
			}
			r.add("codex           %s  已移除 %s%s", p.CodexConfig, slug, bakNote(bak))
		}
	}

	// Codex auth.json: only remove the key if we wrote it.
	if st.Applied.WroteAuthKey {
		if obj, _, err := readJSONObject(p.CodexAuth); err == nil {
			if _, has := obj["OPENAI_API_KEY"]; has {
				delete(obj, "OPENAI_API_KEY")
				bak, werr := writeValidated(p.CodexAuth, marshalJSON(obj), 0600, validateJSONBytes)
				if werr != nil {
					return r, werr
				}
				r.add("codex           %s  已移除本工具写入的 OPENAI_API_KEY%s", p.CodexAuth, bakNote(bak))
			}
		}
	}

	st.Applied = Applied{}
	return r, nil
}

// ---------------------------------------------------------------------------
// CLI

func usage() {
	fmt.Print(`ccswitch-lite ` + version + ` — Claude Desktop / Claude Code / Codex 供应商切换

用法:
  ccswitch list                         列出供应商
  ccswitch add [选项]                   添加或更新供应商
      --name NAME --base-url URL --api-key KEY
      --format anthropic|openai         (默认 anthropic)
      --default-model MODEL             写入 ANTHROPIC_MODEL
      --sonnet/--opus/--haiku/--fable MODEL
      --header "K=V"                    可重复，写入 Codex http_headers
      --apply                           添加后立即应用
  ccswitch use <name>                   选中并应用到所有目标
  ccswitch apply [--name NAME]          应用当前（或指定）供应商
  ccswitch restore                      恢复 Claude Desktop 1P，并清理本工具写入项
  ccswitch web [--addr 127.0.0.1:18081] 启动浏览器管理界面
  ccswitch version

配置文件: ~/.config/ccswitch-lite/providers.json（遵循 XDG_CONFIG_HOME）
`)
}

type headerFlag map[string]string

func (h headerFlag) String() string { return "" }
func (h headerFlag) Set(v string) error {
	k, val, ok := strings.Cut(v, "=")
	if !ok || strings.TrimSpace(k) == "" {
		return fmt.Errorf("--header 需要 K=V 形式: %q", v)
	}
	h[strings.TrimSpace(k)] = val
	return nil
}

func isTTY() bool {
	st, err := os.Stdin.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}

func prompt(label string) string {
	fmt.Print(label)
	sc := bufio.NewScanner(os.Stdin)
	if !sc.Scan() {
		return ""
	}
	return strings.TrimSpace(sc.Text())
}

func cmdList(p *Paths) error {
	st, err := loadStore(p)
	if err != nil {
		return err
	}
	if len(st.Providers) == 0 {
		fmt.Println("尚未配置任何供应商。运行 ccswitch add 或 ccswitch web。")
		return nil
	}
	fmt.Printf("%-2s %-20s %-10s %-40s %s\n", "", "NAME", "FORMAT", "BASE URL", "KEY")
	for _, pr := range st.Providers {
		mark := " "
		if pr.Name == st.Current {
			mark = "*"
		}
		fmt.Printf("%-2s %-20s %-10s %-40s %s\n", mark, pr.Name, pr.APIFormat, pr.BaseURL, maskKey(pr.APIKey))
	}
	return nil
}

func cmdAdd(p *Paths, args []string) error {
	fs := flag.NewFlagSet("add", flag.ContinueOnError)
	name := fs.String("name", "", "provider name")
	baseURL := fs.String("base-url", "", "gateway base URL")
	apiKey := fs.String("api-key", "", "API key")
	format := fs.String("format", "anthropic", "anthropic|openai")
	defaultModel := fs.String("default-model", "", "ANTHROPIC_MODEL")
	sonnet := fs.String("sonnet", "", "sonnet model mapping")
	opus := fs.String("opus", "", "opus model mapping")
	haiku := fs.String("haiku", "", "haiku model mapping")
	fable := fs.String("fable", "", "fable model mapping")
	applyNow := fs.Bool("apply", false, "apply after adding")
	headers := headerFlag{}
	fs.Var(headers, "header", "extra header K=V (repeatable)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *name == "" {
		if !isTTY() {
			return errors.New("缺少 --name（非交互模式）")
		}
		*name = prompt("名称: ")
	}
	if *baseURL == "" {
		if !isTTY() {
			return errors.New("缺少 --base-url（非交互模式）")
		}
		*baseURL = prompt("Base URL: ")
	}
	if *apiKey == "" {
		if !isTTY() {
			return errors.New("缺少 --api-key（非交互模式）")
		}
		*apiKey = prompt("API Key: ")
	}
	if isTTY() && *sonnet == "" && *opus == "" && *haiku == "" && *fable == "" {
		fmt.Println("模型映射可直接回车跳过（格式: 上游模型名，可加 [1m] 后缀）")
		*sonnet = prompt("  sonnet: ")
		*opus = prompt("  opus:   ")
		*haiku = prompt("  haiku:  ")
		*fable = prompt("  fable:  ")
	}

	pr := Provider{
		Name:         *name,
		BaseURL:      *baseURL,
		APIKey:       *apiKey,
		APIFormat:    *format,
		DefaultModel: strings.TrimSpace(*defaultModel),
		Models: Models{
			Sonnet: strings.TrimSpace(*sonnet),
			Opus:   strings.TrimSpace(*opus),
			Haiku:  strings.TrimSpace(*haiku),
			Fable:  strings.TrimSpace(*fable),
		},
		ExtraHeaders: headers,
	}
	if err := normalizeProvider(&pr); err != nil {
		return err
	}

	storeMu.Lock()
	defer storeMu.Unlock()
	st, err := loadStore(p)
	if err != nil {
		return err
	}
	st.upsert(pr)
	if st.Current == "" {
		st.Current = pr.Name
	}
	if err := saveStore(p, st); err != nil {
		return err
	}
	fmt.Printf("已保存供应商 %q（%s，%s）\n", pr.Name, pr.APIFormat, pr.BaseURL)
	if *applyNow {
		return doApply(p, st, &pr)
	}
	return nil
}

func cmdUse(p *Paths, args []string) error {
	fs := flag.NewFlagSet("use", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("用法: ccswitch use <name>")
	}
	name := fs.Arg(0)
	storeMu.Lock()
	defer storeMu.Unlock()
	st, err := loadStore(p)
	if err != nil {
		return err
	}
	pr := st.find(name)
	if pr == nil {
		return fmt.Errorf("未找到供应商 %q（先运行 ccswitch list）", name)
	}
	st.Current = name
	if err := saveStore(p, st); err != nil {
		return err
	}
	return doApply(p, st, pr)
}

func cmdApply(p *Paths, args []string) error {
	fs := flag.NewFlagSet("apply", flag.ContinueOnError)
	name := fs.String("name", "", "apply this provider instead of current")
	if err := fs.Parse(args); err != nil {
		return err
	}
	storeMu.Lock()
	defer storeMu.Unlock()
	st, err := loadStore(p)
	if err != nil {
		return err
	}
	target := *name
	if target == "" {
		target = st.Current
	}
	if target == "" {
		return errors.New("没有选中的供应商；先运行 ccswitch use <name> 或 ccswitch add --apply")
	}
	pr := st.find(target)
	if pr == nil {
		return fmt.Errorf("未找到供应商 %q", target)
	}
	return doApply(p, st, pr)
}

func doApply(p *Paths, st *Store, pr *Provider) error {
	r, err := applyProvider(p, pr, st)
	for _, line := range r.lines {
		fmt.Println("  " + line)
	}
	if err != nil {
		return err
	}
	if err := saveStore(p, st); err != nil {
		return fmt.Errorf("配置已写入，但保存状态失败: %w", err)
	}
	audit(p, "apply provider=%q codex=%s", pr.Name, st.Applied.CodexSlug)
	fmt.Printf("已应用 %q 到 Claude Desktop / Claude Code / Codex\n", pr.Name)
	fmt.Printf("提示: Codex 通过 env_key 读取 OPENAI_API_KEY；auth.json 已在不覆盖已有密钥的前提下尽力写入。\n")
	return nil
}

func cmdRestore(p *Paths, args []string) error {
	fs := flag.NewFlagSet("restore", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	storeMu.Lock()
	defer storeMu.Unlock()
	st, err := loadStore(p)
	if err != nil {
		return err
	}
	r, err := restoreAll(p, st)
	for _, line := range r.lines {
		fmt.Println("  " + line)
	}
	if err != nil {
		return err
	}
	if err := saveStore(p, st); err != nil {
		return err
	}
	audit(p, "restore")
	fmt.Println("已恢复 Claude Desktop 为 1P，并清理本工具写入的 Claude Code / Codex 配置。")
	return nil
}

func audit(p *Paths, format string, a ...any) {
	_ = os.MkdirAll(filepath.Dir(p.LogFile), 0700)
	f, err := os.OpenFile(p.LogFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, a...))
}

// ---------------------------------------------------------------------------
// web UI

func cmdWeb(p *Paths, args []string) error {
	fs := flag.NewFlagSet("web", flag.ContinueOnError)
	addr := fs.String("addr", defaultAddr, "listen address")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if err := ensureLoopback(*addr); err != nil {
		return err
	}
	token, err := loadOrCreateWebToken(p)
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, indexHTML)
	})
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			methodNotAllowed(w)
			return
		}
		storeMu.Lock()
		defer storeMu.Unlock()
		st, err := loadStore(p)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		writeJSON(w, 200, map[string]any{
			"current":   st.Current,
			"providers": publicProviders(st.Providers),
			"version":   version,
		})
	})
	mux.HandleFunc("/api/providers", func(w http.ResponseWriter, r *http.Request) {
		storeMu.Lock()
		defer storeMu.Unlock()
		switch r.Method {
		case http.MethodPost:
			var in Provider
			if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in); err != nil {
				writeErr(w, 400, fmt.Errorf("请求体不是合法 JSON: %w", err))
				return
			}
			st, err := loadStore(p)
			if err != nil {
				writeErr(w, 500, err)
				return
			}
			existing := st.find(in.Name)
			if in.APIKey == "" && existing != nil {
				in.APIKey = existing.APIKey
			}
			if in.ExtraHeaders == nil && existing != nil {
				in.ExtraHeaders = existing.ExtraHeaders
			}
			// The state endpoint masks sensitive header values; keep the stored
			// value when the form submits the mask (or an empty field) back.
			if existing != nil {
				for k, v := range in.ExtraHeaders {
					if old, ok := existing.ExtraHeaders[k]; ok && (v == "" || v == maskKey(old)) {
						in.ExtraHeaders[k] = old
					}
				}
			}
			if err := normalizeProvider(&in); err != nil {
				writeErr(w, 400, err)
				return
			}
			st.upsert(in)
			if st.Current == "" {
				st.Current = in.Name
			}
			if err := saveStore(p, st); err != nil {
				writeErr(w, 500, err)
				return
			}
			writeJSON(w, 200, map[string]any{"ok": true, "message": "已保存 " + in.Name})
		case http.MethodDelete:
			name := r.URL.Query().Get("name")
			if name == "" {
				writeErr(w, 400, errors.New("缺少 name 参数"))
				return
			}
			st, err := loadStore(p)
			if err != nil {
				writeErr(w, 500, err)
				return
			}
			if !st.remove(name) {
				writeErr(w, 404, fmt.Errorf("未找到 %q", name))
				return
			}
			if err := saveStore(p, st); err != nil {
				writeErr(w, 500, err)
				return
			}
			writeJSON(w, 200, map[string]any{"ok": true, "message": "已删除 " + name})
		default:
			methodNotAllowed(w)
		}
	})
	mux.HandleFunc("/api/use", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			methodNotAllowed(w)
			return
		}
		var in struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in); err != nil {
			writeErr(w, 400, err)
			return
		}
		storeMu.Lock()
		defer storeMu.Unlock()
		st, err := loadStore(p)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		pr := st.find(in.Name)
		if pr == nil {
			writeErr(w, 404, fmt.Errorf("未找到 %q", in.Name))
			return
		}
		st.Current = in.Name
		rep, err := applyProvider(p, pr, st)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		if err := saveStore(p, st); err != nil {
			writeErr(w, 500, err)
			return
		}
		audit(p, "web-use provider=%q", in.Name)
		writeJSON(w, 200, map[string]any{"ok": true, "message": "已应用 " + in.Name, "details": rep.lines})
	})
	mux.HandleFunc("/api/apply", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			methodNotAllowed(w)
			return
		}
		storeMu.Lock()
		defer storeMu.Unlock()
		st, err := loadStore(p)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		pr := st.find(st.Current)
		if pr == nil {
			writeErr(w, 400, errors.New("没有选中的供应商"))
			return
		}
		rep, err := applyProvider(p, pr, st)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		if err := saveStore(p, st); err != nil {
			writeErr(w, 500, err)
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true, "message": "已应用 " + pr.Name, "details": rep.lines})
	})
	mux.HandleFunc("/api/restore", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			methodNotAllowed(w)
			return
		}
		storeMu.Lock()
		defer storeMu.Unlock()
		st, err := loadStore(p)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		rep, err := restoreAll(p, st)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		if err := saveStore(p, st); err != nil {
			writeErr(w, 500, err)
			return
		}
		audit(p, "web-restore")
		writeJSON(w, 200, map[string]any{"ok": true, "message": "已恢复官方模式", "details": rep.lines})
	})

	srv := &http.Server{
		Addr:              *addr,
		Handler:           webGuard(mux, token),
		ReadHeaderTimeout: 5 * time.Second,
	}
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		return fmt.Errorf("监听 %s 失败: %w", *addr, err)
	}
	fmt.Printf("ccswitch-lite web UI: http://%s/?token=%s\n", *addr, token)
	fmt.Println("本机 API 需要该 token；token 文件权限为 0600。按 Ctrl-C 退出。")
	done := make(chan os.Signal, 1)
	signal.Notify(done, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-done
		srv.Close()
	}()
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func ensureLoopback(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("非法地址 %q: %w", addr, err)
	}
	if host == "localhost" {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("为安全起见只允许监听回环地址，收到 %q", addr)
	}
	return nil
}

// hostIsLoopback accepts a bare host or host:port whose host is localhost or a
// loopback IP.  It is used for both the Host header and the Origin header.
func hostIsLoopback(hostport string) bool {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// webGuard blocks cross-site writes to the local UI.  Binding to loopback is
// not enough: any web page can POST to 127.0.0.1 unless the server rejects
// requests whose Host is not loopback, whose Origin is not same-site, or whose
// body is not declared as JSON (a cross-origin JSON request needs a CORS
// preflight, which this server never grants).
func webTokenPath(p *Paths) string {
	return filepath.Join(p.ConfigHome, "ccswitch-lite", "web-token")
}

// loadOrCreateWebToken keeps the API capability out of the public HTML.  A
// local user who cannot read the 0600 file cannot call /api/*; the launch URL
// carries the token once and the UI moves it to sessionStorage.
func loadOrCreateWebToken(p *Paths) (string, error) {
	if v := strings.TrimSpace(os.Getenv("CCSWITCH_WEB_TOKEN")); v != "" {
		if len(v) < 16 {
			return "", errors.New("CCSWITCH_WEB_TOKEN must be at least 16 characters")
		}
		return v, nil
	}
	path := webTokenPath(p)
	if data, err := os.ReadFile(path); err == nil {
		_ = os.Chmod(path, 0600)
		if v := strings.TrimSpace(string(data)); len(v) >= 16 {
			return v, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	token := hex.EncodeToString(raw[:])
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(token+"\n"), 0600); err != nil {
		return "", err
	}
	_ = os.Chmod(path, 0600)
	return token, nil
}

func requestToken(r *http.Request) string {
	if v := strings.TrimSpace(r.Header.Get("X-CCSwitch-Token")); v != "" {
		return v
	}
	if v := strings.TrimSpace(r.Header.Get("Authorization")); strings.HasPrefix(v, "Bearer ") {
		return strings.TrimSpace(strings.TrimPrefix(v, "Bearer "))
	}
	return ""
}

func tokenEqual(got, want string) bool {
	return len(got) == len(want) &&
		subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func webGuard(next http.Handler, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !hostIsLoopback(r.Host) {
			writeErr(w, http.StatusForbidden, errors.New("只接受本机回环 Host"))
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" {
			u, err := url.Parse(origin)
			// Same-origin is required, not merely loopback: another local
			// service on a different port must not be able to write here.
			if err != nil || u.Scheme == "" || !strings.EqualFold(u.Host, r.Host) {
				writeErr(w, http.StatusForbidden, errors.New("拒绝跨站请求"))
				return
			}
		}
		if r.URL.Path == "/api" || strings.HasPrefix(r.URL.Path, "/api/") {
			if !tokenEqual(requestToken(r), token) {
				w.Header().Set("WWW-Authenticate", "Bearer")
				writeErr(w, http.StatusUnauthorized, errors.New("需要访问 token：请用启动命令输出的 ?token= 地址打开"))
				return
			}
		}
		switch r.Method {
		case http.MethodGet, http.MethodHead:
		default:
			ct := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Type")))
			if !strings.HasPrefix(ct, "application/json") {
				writeErr(w, http.StatusUnsupportedMediaType, errors.New("请求必须使用 application/json"))
				return
			}
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "frame-ancestors 'none'")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func sensitiveHeader(name string) bool {
	n := strings.ToLower(name)
	for _, part := range []string{"authorization", "token", "secret", "api-key", "api_key", "apikey", "cookie"} {
		if strings.Contains(n, part) {
			return true
		}
	}
	return false
}

func publicHeaders(h map[string]string) map[string]string {
	if len(h) == 0 {
		return nil
	}
	out := make(map[string]string, len(h))
	for k, v := range h {
		if sensitiveHeader(k) {
			out[k] = maskKey(v)
		} else {
			out[k] = v
		}
	}
	return out
}

func publicProviders(list []Provider) []map[string]any {
	out := make([]map[string]any, 0, len(list))
	for _, pr := range list {
		item := map[string]any{
			"name":      pr.Name,
			"baseUrl":   pr.BaseURL,
			"apiFormat": pr.APIFormat,
			"models":    pr.Models,
			"maskedKey": maskKey(pr.APIKey),
			"hasKey":    pr.APIKey != "",
		}
		if pr.DefaultModel != "" {
			item["defaultModel"] = pr.DefaultModel
		}
		if len(pr.ExtraHeaders) > 0 {
			item["extraHeaders"] = publicHeaders(pr.ExtraHeaders)
		}
		out = append(out, item)
	}
	return out
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, err error) {
	writeJSON(w, code, map[string]any{"ok": false, "error": err.Error()})
}

func methodNotAllowed(w http.ResponseWriter) {
	writeErr(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
}

// ---------------------------------------------------------------------------
// main

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	p, err := resolvePaths()
	if err != nil {
		fmt.Fprintln(os.Stderr, "无法确定配置路径:", err)
		os.Exit(1)
	}
	var cmdErr error
	switch os.Args[1] {
	case "list":
		cmdErr = cmdList(p)
	case "add":
		cmdErr = cmdAdd(p, os.Args[2:])
	case "use":
		cmdErr = cmdUse(p, os.Args[2:])
	case "apply":
		cmdErr = cmdApply(p, os.Args[2:])
	case "restore":
		cmdErr = cmdRestore(p, os.Args[2:])
	case "web":
		cmdErr = cmdWeb(p, os.Args[2:])
	case "version", "--version", "-v":
		fmt.Println("ccswitch-lite", version)
	case "help", "-h", "--help":
		usage()
	default:
		usage()
		os.Exit(2)
	}
	if cmdErr != nil {
		fmt.Fprintln(os.Stderr, "错误:", cmdErr)
		os.Exit(1)
	}
}
