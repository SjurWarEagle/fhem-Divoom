#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes;
use Net::Bluetooth;
use IO::Select;
use Imager;

sub listDevices();
sub connectDivoom($;$);
sub disconnectDivoom();
sub sendRaw($$;$);
sub sendPlain($$;$);
sub convertRawToPlain($);
sub convertImageTB($;$);
sub convertImageAB($;$);

my $socket;
my $TIMEBOX;

sub listDevices()
{
  print "Search for devices...\n\n";  

  my $device_ref = get_remote_devices();
  
  foreach my $addr (keys %$device_ref) 
  {
    print "Address: $addr Name: $device_ref->{$addr}\n";
  }

  print "done\n\n";
}

# aurabox, timebox = port 4
# timebox evo = port 1
sub connectDivoom($)
{
  my $device = shift;
  my $port = shift;
  my $ret;
  my $success = 0;

  print "Create RFCOMM client ($device)...\n";

  $port = 4 if (!defined($port));
  
  $socket = Net::Bluetooth->newsocket("RFCOMM");
  return $success unless(defined($socket));
  
  if (0 != $socket->connect($device, $port)) 
  {
    $socket->close();
    return $success;
  }

  $TIMEBOX = $socket->perlfh();
  
  # timebox evo do not send anything on connect
  if (4 == $port)
  {
    sysread($TIMEBOX, $ret, 256);
    if (defined($ret))
    {
      $ret =~ s/[^[:print:]]//g;
      print "Device answer: $ret";

      if ('HELLO' eq $ret)
      {
        $success = 1;
      }
      else
      {
        close($TIMEBOX);
        $socket->close();
      }
    }
  }
  else
  {
    $success = 1;
  }
  
  print "\ndone\n\n";

  return $success;
}

sub disconnectDivoom()
{
  close($TIMEBOX);
  $socket->close();
}

sub sendRaw($$;$)
{
  my $data = shift;
  my $timeout = shift;
  my $response = shift;
  my $ret;
  my $retry = 0;
  my $select = IO::Select->new($TIMEBOX);
  
  print "Send raw command: $data\n";

  $response = 1 if (!defined($response));
  
  # remove prefix and postfix
  $data = substr($data, 2, -2);
  
  # escape data if needed
  $data =~ s/(01|02|03)(?{ if (0 == ($-[0] & 1)) {'030'.(3+$1)} else {$1} })/$^R/g;

  # add prefix and postfix
  $data = '01'.$data.'02';

  $data =~ s/((?:[0-9a-fA-F]{2})+)/pack('H*', $1)/ge;
  
  do
  {
    syswrite($TIMEBOX, $data);

    if ($select->can_read(0.1))
    {
      sysread($TIMEBOX, $ret, 256);
      if (defined($ret))
      {
        $ret = unpack('(H2)*', $ret);
        $ret =~ s/[^[:print:]]+//g;
        print "Device answer: $ret\n";
      }
    }
    else
    {
      print "No answer from device!\n";
    }

    $retry++;
  } while (($response) && ($retry <= 3) && (!defined($ret) || '01' ne $ret));

  if ($retry > 3)
  {
    print "Failed!\n";
  }
  else
  {
    Time::HiRes::sleep($timeout);
  }

  print "done\n\n";
}

sub sendPlain($$;$)
{
  my $data = shift;
  my $timeout = shift;
  my $response = shift;
  my $crc = 0;
  my $ret;
  my $retry = 0;

  print "Send plain command: $data\n";

  # add length (length of data + length of checksum)
  $_ = (length($data) + 4) / 2;
  $data = sprintf("%02x", ($_ & 0xFF)).sprintf("%02x", (($_ >> 8) & 0xFF)).$data;

  # calculate crc
  while ($data =~ /(..)/g)
  {
    $crc += hex($1);
  }

  # add crc
  $data .= sprintf("%02x", ($crc & 0xFF)).sprintf("%02x", (($crc >> 8) & 0xFF));  

  # escape data
  $data =~ s/(01|02|03)(?{ if (0 == ($-[0] & 1)) {'030'.(3+$1)} else {$1} })/$^R/g;

  # add prefix and postfix
  $data = '01'.$data.'02';

  print "Generated raw command: $data\n";

  sendRaw($data, $timeout, $response);
}

sub convertRawToPlain($)
{
  my $data = shift;

  print $data."\n";

  # remove prefix and postfix
  $data = substr($data, 2, -2);

  # unescape data
  $data =~ s/(03(04|05|06))(?{ if (0 == ($-[0] & 1)) {'0'.($2-3)} else {$1} })/$^R/g;
  
  #remove length
  $data = substr($data, 4);

  # remove checksum
  $data = substr($data, 0, -4);

  print $data."\n";

  return $data;
}

sub convertImageTB($;$)
{
  my $file = shift;
  my $size = shift;
  my @imgData = (0);
  my $image = Imager->new;
  
  $size = 11 if (!defined($size));
  $image->read(file=>$file) or die "Can't read image ".$file." (".$image->errstr.")\n";
  
  if ('paletted' eq $image->type)
  {
    print "Image: ".$image->getheight()."x".$image->getwidth()." (maxcolors: ".$image->maxcolors.", usedcolors: ".$image->getcolorcount().")\n";
  }
  else
  {
    print "Image: ".$image->getheight()."x".$image->getwidth()." (maxcolors: no palette found, usedcolors: ".$image->getcolorcount().")\n";
  }

  if (defined($image))
  {
    my ($r, $g, $b, $a);
    my $flicflac = 0;    
    my $imageResized = $image->scaleX(pixels=>$size)->scaleY(pixels=>$size); 

    for (my $y = 0; $y < $size; $y++)
    {
      for (my $x = 0; $x < $size; $x++)
      {
        ($r, $g, $b, $a) = $imageResized->getpixel(x=>$x, y=>$y)->rgba();
        
        if (0 == $flicflac)
        {
          if ($a > 32)
          {
            $imgData[-1] = (($r & 0xF0) >> 4) + ($g & 0xF0);
            push(@imgData, (($b & 0xF0) >> 4));
          }
          else
          {
            $imgData[-1] = 0;
            push(@imgData, 0);
          }

          $flicflac = 1;
        }
        else
        {
          if ($a > 32)
          {
            $imgData[-1] += ($r & 0xF0); 
            push(@imgData, (($g & 0xF0) >> 4) + ($b & 0xF0));
          }
          else
          {
            $imgData[-1] += 0;
            push(@imgData, 0);
          }
          push(@imgData, 0);

          $flicflac = 0;
        }
      }
    }
  }
  else
  {
    print "Error: Loading image failed!\n";
  }

  $_ = '';
  foreach my $byte (@imgData)
  {
    $_ .= sprintf("%02x", ($byte & 0xFF));
  }

  return $_;
}

sub convertImageAB($;$)
{
  my $file = shift;
  my $size = shift;
  my @imgData = ();
  my $image = Imager->new;
  my @color = (0, 1, 2, 11, 4, 5, 2, 5, 8, 1, 2, 3, 4, 13, 6, 7); 

  $size = 10;# if (!defined($size));
  $image->read(file=>$file) or die "Can't read image ".$file." (".$image->errstr.")\n";

  if ('paletted' eq $image->type)
  {
    print "Image: ".$image->getheight()."x".$image->getwidth()." (maxcolors: ".$image->maxcolors.", usedcolors: ".$image->getcolorcount().")\n";
  }
  else
  {
    print "Image: ".$image->getheight()."x".$image->getwidth()." (maxcolors: no palette found, usedcolors: ".$image->getcolorcount().")\n";
  }

  if (defined($image))
  {
    my $flicflac = 0;
    #my $imageResized = $image->scaleX(pixels=>$size)->scaleY(pixels=>$size);

    for (my $y = 0; $y < $size; $y++)
    {
      for (my $x = 0; $x < $size; $x++)
      {
        my $index = $image->findcolor(color=>$image->getpixel(x=>$x, y=>$y));
        print "Warning: palette index (".$index.") outside of allowed range at x=".$x." y=".$y."\n" if ($index > 15);
        $index = $index % 16;
                
        if (0 == $flicflac)
        { 
          push(@imgData, $color[$index]);

          $flicflac = 1;
        }
        else
        {
          $imgData[-1] += ($color[$index] << 4); 

          $flicflac = 0;
        }
      }
    }
  }
  else
  {
    print "Error: Loading image failed!\n";
  }

  $_ = '';
  foreach my $byte (@imgData)
  {
    $_ .= sprintf("%02x", ($byte & 0xFF));
  }

  return $_;
}

my $pic1 = convertImageTB('1.png', 11);
my $pic2 = convertImageTB('2.png', 11);
my $pic3 = convertImageTB('3.png', 11);
my $pic4 = convertImageTB('4.png', 11);
my $pic5 = convertImageTB('5.png', 11);
my $pic6 = convertImageTB('6.png', 11);
my $pic7 = convertImageTB('7.png', 11);
my $pic8 = convertImageTB('8.png', 11);

if (connectDivoom('11:75:58:4F:A1:CB'))
{
  sendPlain('4500', 5);
  sendPlain('49000A0A040000'.$pic1, 0, 0);
  sendPlain('49000A0A040100'.$pic2, 0, 0);
  sendPlain('49000A0A040200'.$pic3, 0, 0);
  sendPlain('49000A0A040300'.$pic4, 0, 0);
  sendPlain('49000A0A040400'.$pic5, 0, 0);
  sendPlain('49000A0A040500'.$pic6, 0, 0);
  sendPlain('49000A0A040600'.$pic7, 0, 0);
  sendPlain('49000A0A040700'.$pic8, 20, 0);
  disconnectDivoom();
}
