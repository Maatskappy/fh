import assert from 'node:assert/strict';

export default function increment(input) {
  assert(Number.isInteger(input.number));
  return {answer: input.number + 1};
}
