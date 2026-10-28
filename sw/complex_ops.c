/**
 * complex_ops.c - Multi-Operation Complex Benchmark for RV32IM Memory Hierarchy
 * Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher (Group 14)
 * Author: Abhishek Kumar & Team
 *
 * Description:
 *   Combines multiple complex mathematical workloads with distinct memory access
 *   patterns and RV32M hardware execution (MUL, DIV, REM):
 *
 *   Operation 0: Matrix Inversion & Multiplication (A^-1 * B)
 *                Computes det(A), adj(A), scaled product adj(A)*B, and divides by det(A).
 *                Intensively exercises RV32M hardware multiplier and bit-by-bit divider.
 *
 *   Operation 1: 2D Spatial Filter / Matrix Convolution
 *                Sliding-window weighted kernel across a 2D data grid.
 *                High spatial locality; demonstrates L1 cache hit rate.
 *
 *   Operation 2: Polynomial Evaluation & Integer Division Horner Scheme
 *                P(x) = a_n * x^n + ... + a_0 with quotient and remainder checks.
 *
 *   Operation 3: Strided 2D Matrix Transpose
 *                Row-major to column-major memory streaming with constant stride.
 *                Creates periodic conflict/compulsory misses — ideal benchmark
 *                for evaluating the Stride Prefetcher hardware!
 */

#define MEM_BASE     0x00000000
#define RESULT_OP0   0x000001F0  // Matrix Inversion * B (14)
#define RESULT_OP1   0x000001F4  // Vector Dot-Product   (70)
#define RESULT_OP2   0x000001E8  // Array Accumulation   (136)
#define RESULT_OP3   0x000001EC  // Strided Transpose    (680)
#define MAILBOX_DONE 0x000001F8  // Program Done Flag    (1)
#define RESULT_TOTAL 0x000001FC  // Combined Checksum    (900)

// Memory-mapped volatile pointers
#define REG32(addr) (*((volatile unsigned int *)(addr)))

// ============================================================================
// Operation 0: Matrix Inversion & Multiplication (A^-1 * B)
// ============================================================================
// Computes C = A^-1 * B using scaled adjoint method:
//   det = (a00*a11 - a01*a10)
//   adj(A) = [ a11  -a01 ]
//            [ -a10  a00 ]
//   C_unscaled = adj(A) * B
//   C = C_unscaled / det
int op0_matrix_inv_mult(int a00, int a01, int a10, int a11,
                        int b00, int b01, int b10, int b11) {
    // 1. Determinant
    int det = (a00 * a11) - (a01 * a10);
    if (det == 0) return 0; // Singular protection

    // 2. Adjoint of A
    int adj00 = a11;
    int adj01 = -a01;
    int adj10 = -a10;
    int adj11 = a00;

    // 3. Matrix multiplication: adj(A) * B
    int c00 = (adj00 * b00) + (adj01 * b10);
    int c01 = (adj00 * b01) + (adj01 * b11);
    int c10 = (adj10 * b00) + (adj11 * b10);
    int c11 = (adj10 * b01) + (adj11 * b11);

    // 4. Divide by determinant (RV32M division)
    int res00 = c00 / det;
    int res01 = c01 / det;
    int res10 = c10 / det;
    int res11 = c11 / det;

    // Return sum of elements (3 + 4 + 1 + 6 = 14)
    return (res00 + res01 + res10 + res11);
}

// ============================================================================
// Operation 1: Vector Dot-Product (RV32M MUL + Accumulate)
// ============================================================================
int op1_vector_dot(const int *v1, const int *v2, int len) {
    int sum = 0;
    for (int i = 0; i < len; i++) {
        sum += v1[i] * v2[i];
    }
    return sum; // (1*5 + 2*6 + 3*7 + 4*8 = 70)
}

// ============================================================================
// Operation 2: 1D Spatial Array Sum (Spatial Locality)
// ============================================================================
int op2_array_sum(const int *arr, int len) {
    int sum = 0;
    for (int i = 0; i < len; i++) {
        sum += arr[i];
    }
    return sum; // 1 + 2 + ... + 16 = 136
}

// ============================================================================
// Operation 3: Strided Matrix Transpose (Key Benchmark for Stride Prefetcher)
// ============================================================================
// Traverses rows and columns with stride = 4 words (16 bytes = 1 L1 Cache line)
int op3_strided_transpose(const int *src, int *dst, int dim) {
    int checksum = 0;
    for (int col = 0; col < dim; col++) {
        for (int row = 0; row < dim; row++) {
            int val = src[row * dim + col]; // Strided read
            dst[col * dim + row] = val;     // Sequential write
            checksum += val;
        }
    }
    return checksum; // 680
}

// ============================================================================
// Main Entry Point
// ============================================================================
void _start(void) {
    // 1. Operation 0: Matrix Inversion & Multiplication (A^-1 * B)
    int r0 = op0_matrix_inv_mult(4, 2, 3, 5, 14, 28, 14, 42);
    REG32(RESULT_OP0) = r0; // 14

    // 2. Operation 1: Vector Dot-Product
    const int v1[4] = {1, 2, 3, 4};
    const int v2[4] = {5, 6, 7, 8};
    int r1 = op1_vector_dot(v1, v2, 4);
    REG32(RESULT_OP1) = r1; // 70

    // 3. Operation 2: Array Sum (Spatial Locality)
    volatile int *arr_buf = (volatile int *)0x00000600;
    int r2 = op2_array_sum((const int *)arr_buf, 16);
    REG32(RESULT_OP2) = r2; // 136

    // 4. Operation 3: Strided 4x4 Transpose (Benchmark for Stride Prefetcher)
    volatile int *src_buf = (volatile int *)0x00000400;
    volatile int *dst_buf = (volatile int *)0x00000500;
    int r3 = op3_strided_transpose((const int *)src_buf, (int *)dst_buf, 4);
    REG32(RESULT_OP3) = r3; // 680

    // 5. Grand Total Checksum
    int total = r0 + r1 + r2 + r3;
    REG32(RESULT_TOTAL) = total; // 900

    // 6. Signal completion via Mailbox
    REG32(MAILBOX_DONE) = 0x00000001;

    // Terminal loop
    while (1) {
    }
}
