// A tiny app for the profile end-to-end test: slugify is the hot spot.
import { slugify, wordCount } from './textutil.mjs';

let total = 0;
for (let i = 0; i < 300000; i++) total += slugify(`Hello World ${i} -- Zig Anything!`).length;
total += wordCount('one two three');
console.log(total);
