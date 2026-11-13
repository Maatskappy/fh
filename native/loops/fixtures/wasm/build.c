/* Developer-only fixture compiler; ordinary tests consume checked-in .wasm. */
#include <wasmtime.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  FILE *in = fopen(argv[1], "rb"); if (!in) return 3;
  fseek(in, 0, SEEK_END); long size = ftell(in); rewind(in);
  char *text = malloc(size); if (!text || fread(text, 1, size, in) != (size_t)size) return 4;
  fclose(in); wasm_byte_vec_t bytes;
  wasmtime_error_t *err = wasmtime_wat2wasm(text, size, &bytes); free(text);
  if (err) { wasm_name_t msg; wasmtime_error_message(err, &msg); fwrite(msg.data, 1, msg.size, stderr); wasm_byte_vec_delete(&msg); wasmtime_error_delete(err); return 5; }
  FILE *out = fopen(argv[2], "wb"); if (!out) return 6;
  int ok = fwrite(bytes.data, 1, bytes.size, out) == bytes.size && fclose(out) == 0;
  wasm_byte_vec_delete(&bytes); return ok ? 0 : 7;
}
