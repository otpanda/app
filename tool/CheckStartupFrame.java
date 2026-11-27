import java.awt.image.BufferedImage;
import java.io.File;
import javax.imageio.ImageIO;

// Examine only the app body, excluding Android status/navigation bars and app bar.
// This catches a semantics-ready black compositor frame without depending on theme.
class CheckStartupFrame {
 public static void main(String[] args) throws Exception {
  BufferedImage image=ImageIO.read(new File(args[0]));
  if(image==null) throw new IllegalArgumentException("Not a decoded image");
  int w=image.getWidth(),h=image.getHeight(),n=0,lit=0,green=0,min=255,max=0;
  for(int y=h/5;y<h*4/5;y+=3) for(int x=w/20;x<w*19/20;x+=3){
   int rgb=image.getRGB(x,y),r=(rgb>>16)&255,g=(rgb>>8)&255,b=rgb&255;
   int v=(r+g+b)/3;n++;if(v>20)lit++;if(g>r+15&&g>b+8&&g>65)green++;
   min=Math.min(min,v);max=Math.max(max,v);
  }
  boolean ok=lit>n/20&&green>n/2000&&max-min>45;
  System.out.println("meaningful app body frame: "+ok);
  if(!ok)System.exit(1);
 }
}
