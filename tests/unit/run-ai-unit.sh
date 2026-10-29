#!/usr/bin/env bash
# AI 검토 모듈 단위 테스트 (네트워크/API 키 불필요: 모의 서버 사용)
# 사용: IMG=<php+curl 이미지> ./run-ai-unit.sh   (기본: tests/docker/legacy 에서 빌드한 php83 이미지)
set -u
cd "$(dirname "$0")"
IMG="${IMG:-wglegacy-php83}"
docker run --rm -v "$PWD/../..":/wg:ro "$IMG" bash /wg/tests/unit/ai_unit.sh
