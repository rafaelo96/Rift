import Foundation

// MSL source for the measurement prototype of classic MCFI motion estimation
// (hierarchical block matching). Embedding the source here lets the probe build
// its library at runtime — no .metallib resource plumbing — which keeps the
// whole prototype inside this Tools target. The algorithm follows the academic
// references (coarse-to-fine Bierling-style pyramid + local exhaustive search
// around a predicted center with a displacement cost, half-pel refinement at
// the finest level) and is written from scratch — no code derived from the GPL
// mvtools / motion-interp-gpu sources (used only as literature).
//
// Units: motion vectors are stored in HALF-PIXEL units at every level. Integer
// candidates produce even offsets; the finest level adds odd (sub-pixel)
// candidates via bilinear reads. A vector inherits from the coarser level by
// scaling x2 per level (one coarse pixel = two fine pixels); the per-axis
// inherit factor from a coarse grid to a fine grid is blockSizeRatio * 2.

let motionShadersMSL = """
#include <metal_stdlib>
using namespace metal;

constant int THREADS = 64;
constant int MAX_BS = 16;

struct MEUniforms {
    uint  level;          // pyramid level index (0 = finest / full work size)
    uint  width;
    uint  height;
    uint  blockSize;
    uint  gridW;
    uint  gridH;
    int   searchHalfPel;  // search radius in half-pel units (even = pixel-aligned candidates)
    uint  lambdaPx;       // true-motion penalty: cost = sad + area*lambdaPx*distPx
    uint  halfPelRefine;  // 1 → evaluate +-0.5px offsets around the best integer MV (finest level)
    uint  clearWinGate;   // 1 → keep the best MV only if clear-win over zero displacement (finest level)
    uint  hasInherited;   // 1 → seed the search center from the coarser level MV buffer
    uint2 inheritedGrid;  // coarse level block grid dims
    uint  inheritFactor;  // per-axis factor from coarse grid to this grid
};

static inline int floorDiv2(int v) {
    // floor(v/2) — needed so negative half-pel values decompose like
    // k = 2*base + frac with frac in {0,1} and base = floor(k/2).
    return v >= 0 ? v / 2 : -((-v + 1) / 2);
}

// SAD of the current block (in shared memory wgCur) against a reference location
// displaced by `hp` (half-pel units; full pixels = hp/2 via floorDiv2). Reads are
// direct texture accesses clamped at the image edge. The displacement is evaluated
// exactly where it lands — unlike the old code, which measured SAD near the block
// origin in a fixed ±searchPx window and then simply ADDED the inherited center on
// top, mechanically amplifying coarse corner saturation into spurious round vectors
// like (424,-424).
static inline uint sadAtDirect(
    texture2d<uint, access::read> refTex,
    const threadgroup uint *wgCur,
    int bs, int origX, int origY, int mxx, int mxy, int2 hp)
{
    uint s = 0;
    const int2 base = int2(origX, origY) + int2(floorDiv2(hp.x), floorDiv2(hp.y));
    for (int ly = 0; ly < bs; ++ly) {
        const threadgroup uint *curRow = wgCur + (ly * bs);
        const int py = clamp(base.y + ly, 0, mxy);
        for (int lx = 0; lx < bs; ++lx) {
            const int px = clamp(base.x + lx, 0, mxx);
            const uint refv = refTex.read(uint2(uint(px), uint(py))).x;
            const uint a = curRow[lx];
            s += (a > refv) ? (a - refv) : (refv - a);
        }
    }
    return s;
}

// Linear-in-distance true-motion term: cost = sad + area*lambda*distPx.
// A quadratic term over-penalizes large displacements at coarse levels where a
// genuine long-range SAD gain is beaten by a huge penalty, collapsing every level
// onto zero on fast content. Linear keeps jitter penalized while letting real
// long-range matches win.
static inline uint meCost(uint sad, uint area, uint lambdaPx, int2 hp) {
    const int ax = hp.x < 0 ? -hp.x : hp.x;
    const int ay = hp.y < 0 ? -hp.y : hp.y;
    const uint distPx = uint(sqrt(float(ax * ax + ay * ay)) / 2.0f);
    return sad + area * lambdaPx * distPx;
}

kernel void pyramidDownsample(
    texture2d<uint, access::read>  inTex  [[texture(0)]],
    texture2d<uint, access::write> outTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    const int inW = int(inTex.get_width());
    const int inH = int(inTex.get_height());
    const int cx = 2 * int(gid.x);
    const int cy = 2 * int(gid.y);
    const int w[5] = {1, 4, 6, 4, 1};
    uint sum = 0;
    for (int j = -2; j <= 2; ++j) {
        const int yy = clamp(cy + j, 0, inH - 1);
        uint row = 0;
        for (int i = -2; i <= 2; ++i) {
            const int xx = clamp(cx + i, 0, inW - 1);
            row += uint(w[i + 2]) * inTex.read(uint2(uint(xx), uint(yy))).x;
        }
        sum += uint(w[j + 2]) * row;
    }
    // separable weights (1,4,6,4,1)/16 each axis → total divisor 256
    outTex.write(sum >> 8, gid);
}

kernel void motionSearch(
    texture2d<uint, access::read> curTex     [[texture(0)]],
    texture2d<uint, access::read> refTex     [[texture(1)]],
    device const int2 *inheritedMV           [[buffer(0)]],
    device int2 *outMV                       [[buffer(1)]],
    constant MEUniforms &u                   [[buffer(2)]],
    threadgroup uint *wgRef                  [[threadgroup(0)]],
    uint3 tig [[threadgroup_position_in_grid]],
    uint3 tid [[thread_position_in_threadgroup]])
{
    // One threadgroup per block, block at (tig.x, tig.y). The reference window
    // is DYNAMIC threadgroup memory, sized per dispatch (setThreadgroupMemoryLength
    // in the host) to exactly winW*winW*4 bytes — so L0 allocates 1KB and the
    // wide diagnostic window 24KB, keeping GPU occupancy high (a static
    // MAX_WIN=78 array would starve occupancy and triple L0 latency).
    const int bs = int(u.blockSize);
    const int searchPx = u.searchHalfPel >> 1;
    const int curTotal = bs * bs;
    const int origX = int(tig.x) * bs;
    const int origY = int(tig.y) * bs;
    const int mxx = int(u.width) - 1;
    const int mxy = int(u.height) - 1;

    threadgroup uint wgCur[MAX_BS * MAX_BS];
    // Cooperative load of the bs^2 current block into shared memory. Reads clamp
    // at the image edge. (wgRef — the dynamic threadgroup(0) window — is retained
    // in the signature for host compatibility but no longer used: candidate SADs
    // are evaluated by direct texture reads at their true displacement, so a
    // fixed ±searchPx window around the block origin cannot represent the large
    // inherited centers that the EPZS predictions must actually test.)
    for (uint i = tid.x; i < uint(curTotal); i += THREADS) {
        const int lx = int(i) % bs;
        const int ly = int(i) / bs;
        const int px = clamp(origX + lx, 0, mxx);
        const int py = clamp(origY + ly, 0, mxy);
        wgCur[i] = curTex.read(uint2(uint(px), uint(py))).x;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // MEUniforms does not carry a convention for an unsafe-none flag, so all
    // direct reads clamp to [0, edge] — same policy the removed window used.
    // The area (bs^2) is wide enough that edge clamps only touch the outermost
    // blocks of the frame, matching the previous behavior.
    const uint area = uint(bs * bs);

    // EPZS/HDS candidate prediction set (half-pel units). Every candidate is
    // evaluated at its TRUE displacement (sadAtDirect), so an inherited center
    // that no longer matches the content cannot win: it is compared on equal
    // footing against zero, so graded errors do not propagate.
    const uint parentX = (u.hasInherited != 0)
        ? min(tig.x / u.inheritFactor, u.inheritedGrid.x - 1) : 0;
    const uint parentY = (u.hasInherited != 0)
        ? min(tig.y / u.inheritFactor, u.inheritedGrid.y - 1) : 0;
    int2 cand[4];
    uint candN = 1;
    cand[0] = int2(0, 0);
    if (u.hasInherited != 0) {
        const uint pIdx = parentY * u.inheritedGrid.x + parentX;
        cand[candN++] = 2 * inheritedMV[pIdx];
        const uint pL = min(pIdx + 1, u.inheritedGrid.x * u.inheritedGrid.y - 1);
        const uint pU = min(pIdx + u.inheritedGrid.x, u.inheritedGrid.x * u.inheritedGrid.y - 1);
        if (parentX + 1 < u.inheritedGrid.x) cand[candN++] = 2 * inheritedMV[pL];
        else cand[candN++] = 2 * inheritedMV[pIdx];
        if (parentY + 1 < u.inheritedGrid.y) cand[candN++] = 2 * inheritedMV[pU];
        else cand[candN++] = 2 * inheritedMV[pIdx];
    }

    threadgroup uint prC[THREADS];
    threadgroup int2 prMV[THREADS];
    prC[tid.x] = 0xFFFFFFFFu;
    prMV[tid.x] = int2(0, 0);
    // Evaluate the EPZS predictors in parallel. Zero (cand[0]) is always present,
    // so a large inherited center that no longer matches content is out-voted by
    // zero rather than blindly propagated (this removes the ×2 amplification of
    // coarse corner saturation). Left/up spatial predictors come from the same
    // coarser field, so they are available without an extra pass.
    for (uint c = tid.x; c < candN; c += THREADS) {
        const uint sad = sadAtDirect(refTex, wgCur, bs, origX, origY, mxx, mxy, cand[c]);
        const uint cost = meCost(sad, area, u.lambdaPx, cand[c]);
        prC[tid.x] = cost;
        prMV[tid.x] = cand[c];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint bestCost = prC[0];
    int2 best = prMV[0];
    for (uint c = 1; c < THREADS; ++c) {
        if (prC[c] < bestCost) { bestCost = prC[c]; best = prMV[c]; }
    }

    uint zeroSAD = 0xFFFFFFFFu;
    if (tid.x == 0) {
        for (uint k = 0; k < candN; ++k) {
            if (cand[k].x == 0 && cand[k].y == 0) { zeroSAD = sadAtDirect(refTex, wgCur, bs, origX, origY, mxx, mxy, cand[k]); break; }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Local exhaustive refinement around the winning prediction. The reference
    // window is (re)loaded centered on `best` — a pixel-aligned block origin at
    // (origX,origY) + floorDiv2(best) — covering ±searchPx around it, so the
    // refine reads from shared memory (fast) while evaluating displacements
    // relative to the EPZS prediction, not blindly added to an unvalidated
    // center. Relative offset (ox,oy) in [-searchPx,+searchPx] pixels maps to
    // window index (searchPx+ox, searchPx+oy); final MV = best + 2*(ox,oy).
    const int searchPxWin = searchPx;
    const int winW = bs + 2 * searchPxWin;
    const int winTotal = winW * winW;
    const int cpx = origX + floorDiv2(best.x);
    const int cpy = origY + floorDiv2(best.y);
    for (uint i = tid.x; i < uint(winTotal); i += THREADS) {
        const int lx = int(i) % winW;
        const int ly = int(i) / winW;
        const int px = clamp(cpx - searchPxWin + lx, 0, mxx);
        const int py = clamp(cpy - searchPxWin + ly, 0, mxy);
        wgRef[i] = refTex.read(uint2(uint(px), uint(py))).x;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const int d = 2 * searchPx + 1;
    const int candCnt = d * d;
    uint myC = 0xFFFFFFFFu;
    int2 myMV = best;
    for (int c = int(tid.x); c < candCnt; c += THREADS) {
        const int ox = (c % d) - searchPx;
        const int oy = (c / d) - searchPx;
        uint sad = 0;
        for (int ly = 0; ly < bs; ++ly) {
            const threadgroup uint *curRow = wgCur + uint(ly * bs);
            const threadgroup uint *refRow = wgRef + uint((ly + searchPx + oy) * winW + (searchPx + ox));
            for (int lx = 0; lx < bs; ++lx) {
                const uint a = curRow[lx];
                const uint b = refRow[lx];
                sad += (a > b) ? (a - b) : (b - a);
            }
        }
        const int2 hp = best + int2(2 * ox, 2 * oy);
        const uint cost = meCost(sad, area, u.lambdaPx, hp);
        if (cost < myC) { myC = cost; myMV = hp; }
    }
    prC[tid.x] = myC;
    prMV[tid.x] = myMV;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid.x == 0) {
        int2 mv = prMV[0];
        uint bestCost_i = prC[0];
        for (uint c = 1; c < THREADS; ++c) {
            if (prC[c] < bestCost_i) { bestCost_i = prC[c]; mv = prMV[c]; }
        }

        // Clear-win motion gate (finest level only): suppress MVs that do not
        // beat the zero-displacement prediction by a real margin. This kills
        // the wrong large vectors that flat/smooth blocks produce (SAD noise
        // picks distant textures), which previously turned the compensated
        // error ratio > 1. Margin = ~13% relative gain, matching the probe's
        // "good match" criterion (best < 0.75 * zero).
        if (u.clearWinGate != 0 && u.halfPelRefine != 0 && bestCost_i * 8u >= zeroSAD * 7u && zeroSAD != 0) {
            mv = int2(0, 0);
        }

        if (u.halfPelRefine != 0) {
            const int2 cands[8] = {
                int2(1, 0),   int2(-1, 0),
                int2(0, 1),   int2(0, -1),
                int2(1, 1),   int2(1, -1),
                int2(-1, 1),  int2(-1, -1)
            };
            for (int k = 0; k < 8; ++k) {
                const int2 hp = mv + cands[k]; // odd component(s) -> sub-pixel
                uint hsad = 0;
                const int2 base = int2(origX, origY) + int2(floorDiv2(hp.x), floorDiv2(hp.y));
                const bool fx = (hp.x & 1) != 0;
                const bool fy = (hp.y & 1) != 0;
                const int2 m = int2(int(u.width) - 1, int(u.height) - 1);
                for (int ly = 0; ly < bs; ++ly) {
                    const threadgroup uint *curRow = wgCur + uint(ly * bs);
                    for (int lx = 0; lx < bs; ++lx) {
                        const int2 p = base + int2(lx, ly);
                        const int2 pc0 = clamp(p, int2(0, 0), m);
                        const int2 pc1 = clamp(p + int2(1, 0), int2(0, 0), m);
                        const int2 pc2 = clamp(p + int2(0, 1), int2(0, 0), m);
                        const int2 pc3 = clamp(p + int2(1, 1), int2(0, 0), m);
                        const uint q00 = refTex.read(uint2(uint(pc0.x), uint(pc0.y))).x;
                        const uint q10 = refTex.read(uint2(uint(pc1.x), uint(pc1.y))).x;
                        const uint q01 = refTex.read(uint2(uint(pc2.x), uint(pc2.y))).x;
                        const uint q11 = refTex.read(uint2(uint(pc3.x), uint(pc3.y))).x;
                        const uint vTop = fx ? ((q00 + q10 + 1) >> 1) : q00;
                        const uint vBot = fx ? ((q01 + q11 + 1) >> 1) : q01;
                        const uint ref = fy ? ((vTop + vBot + 1) >> 1) : vTop;
                        const uint a = curRow[lx];
                        hsad += (a > ref) ? (a - ref) : (ref - a);
                    }
                }
                const int ax = hp.x < 0 ? -hp.x : hp.x;
                const int ay = hp.y < 0 ? -hp.y : hp.y;
                const uint distPx = uint(sqrt(float(ax * ax + ay * ay)) / 2.0f);
                const uint cost = hsad + area * u.lambdaPx * distPx;
                if (cost < bestCost_i) {
                    bestCost_i = cost;
                    mv = hp;
                }
            }
        }
        outMV[int(tig.y) * int(u.gridW) + int(tig.x)] = mv;
    }
}

kernel void mvMedian3(
    device const int2 *inMV    [[buffer(0)]],
    device int2 *outMV         [[buffer(1)]],
    constant MEUniforms &u     [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.gridW || gid.y >= u.gridH) return;
    int2 cand[9];
    const int2 centerIn = int2(gid);
    int n = 0;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            const int2 p = centerIn + int2(i, j);
            const uint cx = uint(max(0, min(int(u.gridW) - 1, p.x)));
            const uint cy = uint(max(0, min(int(u.gridH) - 1, p.y)));
            cand[n++] = inMV[cy * u.gridW + cx];
        }
    }
    // Sort ascending by squared half-pel magnitude; take the middle element.
    for (int a = 1; a < n; ++a) {
        const int2 key = cand[a];
        const uint keyM = uint(key.x * key.x + key.y * key.y);
        int b = a - 1;
        while (b >= 0 && uint(cand[b].x * cand[b].x + cand[b].y * cand[b].y) > keyM) {
            cand[b + 1] = cand[b];
            b -= 1;
        }
        cand[b + 1] = key;
    }
    outMV[gid.y * u.gridW + gid.x] = cand[n / 2];
}
"""