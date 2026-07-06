class Args:
    def __init__(self, out):
        self.out = out

task = ('write a two-line poem about code and save it to sig_test.txt', '')
args = (Args(out='sig_test.txt'), '')

poem = "In lines of logic, dreams take flight,\nWith every code, we spark the light."

with open(args[0].out, 'w') as file:
    file.write(poem)