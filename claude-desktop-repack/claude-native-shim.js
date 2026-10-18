"use strict";
// Minimal loong64 JS stand-in for @ant/claude-native.
// Implements the safe-fs primitives used by the desktop main process.
const fs = require("fs");
const path = require("path");
const roots = new Map();

function openRootDir(p) {
  const real = fs.realpathSync(p);
  const fd = fs.openSync(real, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
  roots.set(fd, real);
  return Promise.resolve(fd);
}
function openBeneath(rootFd, segments, flags, mode) {
  const base = roots.get(rootFd);
  if (base === undefined) {
    const e = new Error("EBADF: unknown root handle");
    e.code = "EBADF";
    return Promise.reject(e);
  }
  const target = path.join(base, ...segments.map(String));
  try { return Promise.resolve(fs.openSync(target, flags, mode || 0o600)); }
  catch (e) { return Promise.reject(e); }
}
function mkdirBeneath(rootFd, segments, mode) {
  const base = roots.get(rootFd);
  if (base === undefined) {
    const e = new Error("EBADF: unknown root handle"); e.code = "EBADF";
    return Promise.reject(e);
  }
  try { fs.mkdirSync(path.join(base, ...segments.map(String)), { mode: mode || 0o777 }); return Promise.resolve(); }
  catch (e) { return Promise.reject(e); }
}
function openat(rootFd, rel, flags, mode) {
  return openBeneath(rootFd, String(rel).split("/").filter(Boolean), flags, mode);
}

function _resolve(rootFd, segments) {
  const base = roots.get(rootFd);
  if (base === undefined) { const e = new Error("EBADF: unknown root handle"); e.code = "EBADF"; throw e; }
  return path.join(base, ...segments.map(String));
}
function _p(fn) { try { return Promise.resolve(fn()); } catch (e) { return Promise.reject(e); } }
function renameBeneath(rootFd, fromSegs, toSegs) { return _p(() => fs.renameSync(_resolve(rootFd, fromSegs), _resolve(rootFd, toSegs))); }
function unlinkBeneath(rootFd, segs) { return _p(() => fs.unlinkSync(_resolve(rootFd, segs))); }
function rmdirBeneath(rootFd, segs) { return _p(() => fs.rmdirSync(_resolve(rootFd, segs))); }
function statBeneath(rootFd, segs) { return _p(() => fs.statSync(_resolve(rootFd, segs), { bigint: true })); }

module.exports = { openRootDir, openBeneath, mkdirBeneath, openat, renameBeneath, unlinkBeneath, rmdirBeneath, statBeneath };
