/* Parser self-check for NCCL_RING_EDGE_DEVS (dev-time, not a patch deliverable).
 *
 * The parser under test is extracted BYTE-FOR-BYTE from src/graph/ringpeer.cc
 * into ringparse_extract.inc by the run script (see IMPLEMENTATION.md), so this
 * harness always tests the exact shipped logic.
 *
 * Build & run (from an NCCL tree with ring-nccl.patch applied):
 *   { sed -n -e '/^#define NCCL_RING_MAX_DEVS/p' -e '/^#define NCCL_RING_EDGE_PAIR/p' \
 *         -e '/^#define NCCL_RING_EDGE_CROSS/p' src/graph/ringpeer.cc; \
 *     sed -n '/^static struct ncclRingEdgeDevs {/,/^} gRing/p' src/graph/ringpeer.cc; \
 *     sed -n '/^static bool ncclRingAdjacent/,/^}/p'    src/graph/ringpeer.cc; \
 *     sed -n '/^static int ncclRingEdgeType/,/^}/p'     src/graph/ringpeer.cc; \
 *     sed -n '/^static int ncclRingParse/,/^}/p'        src/graph/ringpeer.cc; } > /tmp/ringparse_extract.inc
 *   g++ -Wall -o /tmp/ringparse_selftest ringparse_selftest.cc && /tmp/ringparse_selftest
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NCCL_TOPO_MAX_NODES 640 /* must match src/include/graph.h on v2.30.7-1 */
#include "/tmp/ringparse_extract.inc"

static int tests = 0, fails = 0;
#define CHECK(cond) \
  do { \
    tests++; \
    if (!(cond)) { \
      fails++; \
      printf("FAIL: %s\n", #cond); \
    } \
  } while (0)

static struct ncclRingEdgeDevs m;
static int ok(const char* s) { return ncclRingParse(&m, s) == 0; }

int main() {
  /* valid */
  CHECK(ok("pair=1,3;cross=0,2"));
  CHECK(m.ndevs[0] == 2 && m.devs[0][0] == 1 && m.devs[0][1] == 3);
  CHECK(m.ndevs[1] == 2 && m.devs[1][0] == 0 && m.devs[1][1] == 2);
  CHECK(ok("cross=0,2;pair=1,3"));         /* key order free */
  CHECK(ok("pair=1;cross=0"));             /* n=1 per class (degraded, user's choice) */
  CHECK(ok("pair=0,1,2,3;cross=3,2,1,0")); /* n=4 per class */
  CHECK(ok("pair=13,31;cross=102,639"));   /* multi-digit, upper-bound index */

  /* malformed -> WARN + init failure in the library, never a silent fallback */
  CHECK(!ok(""));
  CHECK(!ok("pair=1,3"));                   /* missing cross */
  CHECK(!ok("cross=0,2"));                  /* missing pair */
  CHECK(!ok("pair=1,3;pair=0,2"));          /* duplicate key */
  CHECK(!ok("pair=1,3;cross=0,2;pair=5"));  /* duplicate after both keys */
  CHECK(!ok("pair=1,3;"));                  /* trailing ';' */
  CHECK(!ok(";pair=1,3;cross=0,2"));        /* leading ';' */
  CHECK(!ok("pair=1,,3;cross=0,2"));        /* empty dev slot */
  CHECK(!ok("pair=;cross=0,2"));            /* no devs */
  CHECK(!ok("pair=1,3;cross=0,2;foo=1"));   /* unknown key */
  CHECK(!ok("PAIR=1,3;cross=0,2"));         /* keys are case sensitive */
  CHECK(!ok("1=1,3;3=0,2"));                /* legacy per-rank format is NOT accepted */
  CHECK(!ok("pair=a,b;cross=0,2"));         /* non-numeric */
  CHECK(!ok("pair=-1,3;cross=0,2"));        /* negative */
  CHECK(!ok("pair=1,640;cross=0,2"));       /* index >= NCCL_TOPO_MAX_NODES */
  CHECK(!ok("pair=0,1,2,3,4;cross=0,2"));   /* >4 devs per class */
  CHECK(!ok("pair=1 3;cross=0,2"));         /* junk separator */

  /* edge class derivation: all 8 adjacent (rank, peer) pairs of the 4-ring */
  CHECK(ncclRingEdgeType(0, 1) == NCCL_RING_EDGE_PAIR);
  CHECK(ncclRingEdgeType(0, 3) == NCCL_RING_EDGE_CROSS);
  CHECK(ncclRingEdgeType(1, 0) == NCCL_RING_EDGE_PAIR);
  CHECK(ncclRingEdgeType(1, 2) == NCCL_RING_EDGE_CROSS);
  CHECK(ncclRingEdgeType(2, 1) == NCCL_RING_EDGE_CROSS);
  CHECK(ncclRingEdgeType(2, 3) == NCCL_RING_EDGE_PAIR);
  CHECK(ncclRingEdgeType(3, 2) == NCCL_RING_EDGE_PAIR);
  CHECK(ncclRingEdgeType(3, 0) == NCCL_RING_EDGE_CROSS);

  /* SR-4: channel c uses devs[c % n] */
  CHECK(ok("pair=1,3;cross=0,2"));
  CHECK(m.devs[0][0 % 2] == 1 && m.devs[0][1 % 2] == 3 && m.devs[0][2 % 2] == 1);
  CHECK(m.devs[1][0 % 2] == 0 && m.devs[1][1 % 2] == 2 && m.devs[1][2 % 2] == 0);

  /* adjacency helper (SR-1 gate) */
  CHECK(ncclRingAdjacent(0, 1, 4) && ncclRingAdjacent(0, 3, 4));
  CHECK(ncclRingAdjacent(1, 0, 4) && ncclRingAdjacent(1, 2, 4));
  CHECK(!ncclRingAdjacent(0, 2, 4) && !ncclRingAdjacent(1, 3, 4));

  printf("ringparse selftest: %d/%d checks passed\n", tests - fails, tests);
  return fails ? 1 : 0;
}
