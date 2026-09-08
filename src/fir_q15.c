#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define FIR_API __declspec(dllexport)
#else
#define FIR_API __attribute__((visibility("default")))
#endif

typedef struct {
    int16_t previous[2];
} fir_state;

FIR_API void fir_reset(fir_state *state)
{
    state->previous[0] = 0;
    state->previous[1] = 0;
}

/* C division truncates toward zero. Make negative floor semantics explicit. */
static int16_t quantize(int64_t accumulator)
{
    int64_t value = accumulator >= 0
        ? accumulator / 32768
        : -((-accumulator + 32767) / 32768);
    if (value > 32767) return 32767;
    if (value < -32768) return -32768;
    return (int16_t)value;
}

/* Input and output may alias exactly. Partially overlapping buffers are outside
   the API contract. Pointers must be valid; this kernel performs no allocation. */
FIR_API void fir_process(fir_state *state, const int16_t coefficients[3],
                         const int16_t *input, int16_t *output, size_t length)
{
    size_t index;
    for (index = 0; index < length; ++index) {
        int16_t current = input[index];
        int64_t accumulator = (int64_t)coefficients[0] * current
            + (int64_t)coefficients[1] * state->previous[0]
            + (int64_t)coefficients[2] * state->previous[1];
        output[index] = quantize(accumulator);
        state->previous[1] = state->previous[0];
        state->previous[0] = current;
    }
}
