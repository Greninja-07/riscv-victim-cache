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
#define MAILBOX_DONE 0x00001000
#define RESULT_OP0   0x00001004
#define RESULT_OP1   0x00001008
#define RESULT_OP2   0x0000100C
#define RESULT_OP3   0x00001010

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
    // c00 = adj00*b00 + adj01*b10
    // c01 = adj00*b01 + adj01*b11
    // c10 = adj10*b00 + adj11*b10
    // c11 = adj10*b01 + adj11*b11
    int c00 = (adj00 * b00) + (adj01 * b10);
    int c01 = (adj00 * b01) + (adj01 * b11);
    int c10 = (adj10 * b00) + (adj11 * b10);
    int c11 = (adj10 * b01) + (adj11 * b11);

    // 4. Divide by determinant (RV32M division)
    int res00 = c00 / det;
    int res01 = c01 / det;
    int res10 = c10 / det;
    int res11 = c11 / det;

    // Return combined checksum
    return (res00 + res01 + res10 + res11);
}

// ============================================================================
// Operation 1: 2D Spatial Filter / Matrix Convolution
// ============================================================================
// Computes weighted sum over adjacent array elements (Spatial Locality)
int op1_spatial_convolution(const int *data, int size) {
    int sum = 0;
    for (int i = 1; i < size - 1; i++) {
        // 3-point Laplacian / smoothing kernel: [1, -2, 1]
        int val = data[i - 1] - (2 * data[i]) + data[i + 1];
        sum += (val > 0) ? val : -val;
    }
    return sum;
}

// ============================================================================
// Operation 2: Polynomial Horner's Method with Division
// ============================================================================
int op2_polynomial_eval(int x) {
    // P(x) = 3*x^3 - 5*x^2 + 7*x + 11
    int res = 3;
    res = (res * x) - 5;
    res = (res * x) + 7;
    res = (res * x) + 11;

    // Division check
    int quotient  = res / 7;
    int remainder = res % 7;
    return quotient + remainder;
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
    return checksum;
}

// ============================================================================
// Main Entry Point
// ============================================================================
void _start(void) {
    // Input matrices for A^-1 * B
    // A = [ 4,  2 ]   -> det = 4*5 - 2*3 = 14
    //     [ 3,  5 ]
    // B = [ 14, 28 ]
    //     [ 14, 42 ]
    int r0 = op0_matrix_inv_mult(4, 2, 3, 5, 14, 28, 14, 42);
    REG32(RESULT_OP0) = r0;

    // Data buffer for Op 1 & Op 3 (placed in data memory)
    volatile int *buffer_src = (volatile int *)0x00000400;
    volatile int *buffer_dst = (volatile int *)0x00000800;

    // Initialize buffer with test values
    for (int i = 0; i < 32; i++) {
        buffer_src[i] = (i * 17) + 3;
    }

    // Execute Op 1 (Spatial Convolution)
    int r1 = op1_spatial_convolution((const int *)buffer_src, 32);
    REG32(RESULT_OP1) = r1;

    // Execute Op 2 (Polynomial Evaluation at x = 9)
    int r2 = op2_polynomial_eval(9);
    REG32(RESULT_OP2) = r2;

    // Execute Op 3 (Strided 4x4 Transpose)
    int r3 = op3_strided_transpose((const int *)buffer_src, (int *)buffer_dst, 4);
    REG32(RESULT_OP3) = r3;

    // Signal completion via Mailbox
    REG32(MAILBOX_DONE) = 0x00000001;

    // Terminal loop
    while (1) {
        // Halt / wait for reset
    }
}
