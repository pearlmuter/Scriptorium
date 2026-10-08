#!/bin/bash
# Types a short sample manuscript into the running app (debug mode).
D=http://127.0.0.1:7337/debug
curl -s "$D/new" >/dev/null
t(){ curl -s -G "$D/type" --data-urlencode "text=$1" >/dev/null; curl -s "$D/key?name=return" >/dev/null; }
t "# On Rivers"
t "The river was wide that spring. Its flow was gentle and slow, and the willows leaned over the water as if listening for something the rest of us could not hear. We walked along the bank until dark, saying very little, counting the herons as they lifted one by one from the shallows and settled again a little further on."
t "Fleur came home late, as she always did. She said the water had *spoken* to her, which none of us believed. Still, we listened, because there was something in the way she said it — quietly, without any wish to persuade — that made disbelief seem impolite."
t "> A river is a road that moves."
t "In the morning the mist lay so thick over the fields that the river itself had vanished, and only its sound remained to tell us where it ran. Grandmother put the kettle on and said nothing about the night before."
