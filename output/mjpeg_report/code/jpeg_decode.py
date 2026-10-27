        # Pillow is an independent JPEG decoder; fully decompress every frame.
        with Image.open(io.BytesIO(frame.jpeg)) as image:
            if image.format!='JPEG' or image.size!=(self.width,self.height):
                raise ValueError('Independent decoder format/dimension mismatch')
            image.load()
            metadata['decoded_mode']=image.mode
        metadata['decoded']=True
        metadata['raw_yuv422_bytes']=self.width*self.height*2
        metadata['compression_ratio']=metadata['raw_yuv422_bytes']/frame.length
        return metadata
