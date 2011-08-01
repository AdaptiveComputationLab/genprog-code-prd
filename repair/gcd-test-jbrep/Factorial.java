    import java.io.*;

    public class Factorial {
      private static BufferedReader in = new BufferedReader(new
                                InputStreamReader(System.in));

      public static final int fac(int n) {
        return (n == 0)? 1 : n * fac(n - 1);
      }

      public static final int readInt() {
        int n = 4711;
        try {
        System.out.print("Please enter a number> ");
        n = Integer.parseInt(in.readLine());
        } catch(IOException e1) { System.err.println(e1); }
        catch(NumberFormatException e2) { System.err.println(e2); }
        return n;
      }

      public static void main(String[] argv) {
        int n = readInt();
        System.out.println("Factorial of " + n + " is " + fac(n));
      }
    }
